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
#include "cadnext/kernel/OcctKernel.hpp"

#include <cstdio>
#include <cstdlib>
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
    // Accelerate's multithreaded factorisation and BLAS sum in a varying order, so two runs of the same
    // job differed in the last bits (f1 by ~1e-9) — and the Engineering Validation fingerprints results
    // without tolerance, so an unchanged recompute would mark dependent tests stale. One vecLib thread
    // makes every analysis bit-reproducible (measured: static, modal, harmonic, random); it costs ~30 %
    // on a 330k-element study and nothing on small ones. A caller that sets the variable itself keeps
    // its choice.
    setenv("VECLIB_MAXIMUM_THREADS", "1", 0);
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
        const auto& result = study.value();
        std::printf("%s: f1 %.4g Hz, %zu modes, %s\n", job.loadCase.name.c_str(), result.modes.front().frequencyHz,
                    result.modes.size(), result.resonanceOverlap ? "resonance overlap" : "no overlap");
        return 0;
    }

    if (job.analysis == fea::StructuralAnalysis::Shock) {
        const auto study = fea::runShockStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports,
                                              fea::shockStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::shockFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::shockResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: peak stress %.4g Pa at %.4g s, reserve factor %.3f, %s\n", job.loadCase.name.c_str(), result.assessment.limitStressPa,
                    result.finest.timeS[result.finest.worstSample], result.assessment.reserveFactor, fea::verdictName(result.assessment.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Bird) {
        const auto study = fea::runBirdStrikeStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports,
                                                   fea::birdStrikeStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::birdFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::birdResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: %.2f kg at %.0f m/s → %.4g N*s in %.1f us, peak stress %.4g Pa, reserve factor %.3f, %s\n", job.loadCase.name.c_str(),
                    result.impact.normalMomentumNs / std::max(result.impact.normalSpeedMps, 1e-12), result.impact.normalSpeedMps,
                    result.impact.normalMomentumNs, result.impact.totalDurationS * 1e6, result.assessment.limitStressPa,
                    result.assessment.reserveFactor, fea::verdictName(result.assessment.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Lightning) {
        const auto study = fea::runLightningStudy(kernel, shape.value(), *material, job.loadCase.name, fea::lightningStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::lightningFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::lightningResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: peak %.1f K, %s, %s\n", job.loadCase.name.c_str(), result.peakK,
                    result.burnedThrough ? "burn-through" : "no burn-through", fea::verdictName(result.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Flutter) {
        const auto study = fea::runFlutterStudy(kernel, shape.value(), *material, job.loadCase.name, fea::flutterStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::flutterFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::flutterResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: bending %.2f Hz, torsion %.2f Hz, flutter %s, %s\n", job.loadCase.name.c_str(), result.bendingHz, result.torsionHz,
                    result.flutterFound ? (std::to_string(result.flutterSpeedMps) + " m/s").c_str() : "none in the sweep",
                    fea::verdictName(result.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Icing) {
        const auto study = fea::runIcingStudy(kernel, shape.value(), *material, job.loadCase.name, fea::icingStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::icingFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::icingResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: ice %.2f mm, %.3f kg, collection %.3f, %s\n", job.loadCase.name.c_str(), result.maximumIceThicknessM * 1e3, result.iceMassKg,
                    result.collectionEfficiency, fea::verdictName(result.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Emc) {
        const auto study = fea::runEmcStudy(kernel, shape.value(), *material, job.loadCase.name, fea::emcStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::emcFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::emcResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        double worstField = 0.0;
        for (const auto& probe : result.probes) worstField = std::max(worstField, probe.fieldVm);
        std::printf("%s: shielding %.1f dB at %.0f MHz, %.3g V/m inside, %s\n", job.loadCase.name.c_str(), result.worstShieldingDb,
                    result.worstFrequencyHz / 1e6, worstField, fea::verdictName(result.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Fire) {
        const auto study = fea::runFireStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports, fea::fireStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::fireFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::fireResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: peak %.2f K, integrity %s, %s\n", job.loadCase.name.c_str(), result.peakK,
                    result.integrityLost ? ("lost at " + std::to_string(result.failureTimeS) + " s").c_str() : "kept", fea::verdictName(result.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Climate) {
        const auto study = fea::runClimateStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports,
                                                fea::climateStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::climateFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::climateResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: %.2f…%.2f K, thermal stress %.4g Pa, %s\n", job.loadCase.name.c_str(), result.lowK, result.peakK, result.peakStressPa,
                    fea::verdictName(result.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Random) {
        const auto study = fea::runRandomStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports,
                                               fea::randomStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::randomFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::randomResultJson(study.value(), job, fieldReference))) return fail("не удалось записать результат", &job);
        const auto& result = study.value();
        std::printf("%s: RMS von Mises %.4g Pa, 3 sigma %.4g Pa, reserve factor %.3f, %s\n", job.loadCase.name.c_str(),
                    result.levels.back().maxRmsVonMisesPa, result.assessment.limitStressPa, result.assessment.reserveFactor,
                    fea::verdictName(result.assessment.verdict));
        return 0;
    }
    if (job.analysis == fea::StructuralAnalysis::Harmonic) {
        const auto study = fea::runHarmonicStudy(kernel, shape.value(), *material, job.loadCase.name, job.loadCase.supports,
                                                 fea::harmonicStudySettings(job), progress);
        if (!study.isOk()) return fail(study.error().message, &job);
        std::string fieldReference;
        if (!job.fieldPath.empty()) {
            if (!writeFile(job.fieldPath, fea::harmonicFieldJson(study.value()))) return fail("не удалось записать поле", &job);
            fieldReference = std::filesystem::path(job.fieldPath).filename().string();
        }
        if (!writeFile(job.resultPath, fea::harmonicResultJson(study.value(), job, fieldReference))) {
            return fail("не удалось записать результат", &job);
        }
        const auto& result = study.value();
        const auto& worst = result.samples[result.worstSample];
        std::printf("%s: peak dynamic stress %.4g Pa at %.4g Hz, reserve factor %.3f, %s\n", job.loadCase.name.c_str(),
                    worst.maxVonMisesPa, worst.frequencyHz, result.assessment.reserveFactor, fea::verdictName(result.assessment.verdict));
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
    const auto& result = study.value();
    std::printf("%s: σmax %.4g Pa, reserve factor %.3f, %s\n", job.loadCase.name.c_str(), result.assessment.limitStressPa,
                result.assessment.reserveFactor, fea::verdictName(result.assessment.verdict));
    return 0;
}
