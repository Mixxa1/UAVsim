// cadnext_structural — runs one structural job file and writes its result and field files.
//
//   cadnext_structural job.json
//
// Exit status: 0 when the study completed (whatever the verdict — FAIL is an engineering
// answer), 2 when it could not (the result file then says "error" and why), 64 for usage.
// A separate process on purpose: a crashing mesher or an exhausted memory must not take the
// simulator with it, and cancelling a run is terminating the process.

#include "cadnext/bridge/UAVPartReader.hpp"
#include "cadnext/fea/StructuralJob.hpp"
#include "cadnext/fea/StructuralReport.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>

using namespace cadnext;

namespace {

bool readFile(const std::string& path, std::string& out) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return false;
    out.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
    return true;
}

bool writeFile(const std::string& path, const std::string& text) {
    const std::string temporary = path + ".partial";
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        if (!stream) return false;
        stream << text;
        if (!stream) return false;
    }
    std::error_code error;
    std::filesystem::rename(temporary, path, error); // atomic: a reader never sees half a result
    return !error;
}

int fail(const std::string& message, const fea::StructuralJob* job) {
    std::fprintf(stderr, "cadnext_structural: %s\n", message.c_str());
    if (job != nullptr && !job->resultPath.empty()) {
        writeFile(job->resultPath, fea::structuralErrorJson(message, job));
    }
    return 2;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: cadnext_structural <job.json>\n");
        return 64;
    }
    const std::filesystem::path jobPath = std::filesystem::absolute(argv[1]);
    std::string text;
    if (!readFile(jobPath.string(), text)) return fail("не удалось прочитать " + jobPath.string(), nullptr);
    const auto parsed = fea::parseStructuralJob(text, jobPath.parent_path().string());
    if (!parsed.isOk()) return fail(parsed.error().message, nullptr);
    const fea::StructuralJob& job = parsed.value();

    kernel::OcctKernel kernel;
    std::vector<std::uint8_t> brep;
    std::optional<std::string> materialId = job.materialId;
    if (job.geometryFormat == "brep") {
        std::string bytes;
        if (!readFile(job.geometryPath, bytes)) return fail("не удалось прочитать " + job.geometryPath, &job);
        brep.assign(bytes.begin(), bytes.end());
    } else {
        const auto part = bridge::UAVPartReader().readFullPart(job.geometryPath);
        if (!part.isOk()) return fail(part.error().message, &job);
        const auto& geometry = part.value().part.exactGeometry;
        if (!geometry.valid || geometry.representation != "brep_ascii") {
            return fail("в детали нет точной BRep-геометрии (сохранена до UAVPart v1.3?)", &job);
        }
        brep = geometry.payload;
        if (!materialId) materialId = part.value().part.material.materialId;
    }
    if (!materialId) return fail("не задан материал", &job);
    const auto material = fea::findMaterial(*materialId);
    if (!material) return fail("материал " + *materialId + " не найден в базе материалов v" + std::to_string(fea::kMaterialDatabaseVersion), &job);

    const auto shape = kernel.importBRep(brep);
    if (!shape.isOk()) return fail(shape.error().message, &job);

    // One line per step on stdout, "progress <level> <stage>", for a caller showing progress.
    const auto progress = [](int level, const char* stage) {
        std::printf("progress %d %s\n", level, stage);
        std::fflush(stdout);
    };
    if (job.analysis == fea::StructuralAnalysis::Modal) {
        const auto study = fea::runModalStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports,
                                              fea::modalStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        const std::string fieldJson = fea::modalFieldJson(study.value());
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fieldJson)) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        const std::string resultJson = fea::modalResultJson(study.value(), job, fieldReference);
        if (!writeFile(job.resultPath, resultJson)) {
            return fail("не удалось записать результат", &job);
        }
        if (!job.reportPath.empty() && !writeFile(job.reportPath, fea::modalReportHtml(resultJson, fieldJson))) {
            return fail("не удалось записать отчёт", &job);
        }
        const auto& result = study.value();
        std::printf("%s: f1 %.4g Hz, %zu modes, %s\n", job.loadCase.name.c_str(), result.modes.front().frequencyHz,
                    result.modes.size(), result.resonanceOverlap ? "resonance overlap" : "no overlap");
        return 0;
    }

    const auto study = fea::runStructuralStudy(kernel, shape.value(), *material, job.loadCase, job.settings, progress);
    if (!study.isOk()) return fail(study.error().message, &job);

    std::string fieldReference;
    const std::string fieldJson = fea::structuralFieldJson(study.value());
    if (!job.fieldPath.empty()) {
        if (!writeFile(job.fieldPath, fieldJson)) return fail("не удалось записать поле", &job);
        fieldReference = std::filesystem::path(job.fieldPath).filename().string();
    }
    const std::string resultJson = fea::structuralResultJson(study.value(), job, fieldReference);
    if (!writeFile(job.resultPath, resultJson)) {
        return fail("не удалось записать результат", &job);
    }
    if (!job.reportPath.empty() && !writeFile(job.reportPath, fea::structuralReportHtml(resultJson, fieldJson))) {
        return fail("не удалось записать отчёт", &job);
    }
    const auto& result = study.value();
    std::printf("%s: σmax %.4g Pa, reserve factor %.3f, %s\n", job.loadCase.name.c_str(), result.assessment.limitStressPa,
                result.assessment.reserveFactor, fea::verdictName(result.assessment.verdict));
    return 0;
}
