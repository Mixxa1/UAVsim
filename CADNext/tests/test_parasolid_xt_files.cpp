// Standalone Parasolid transmit files (.x_t text, .x_b neutral binary): decoding, exact bodies,
// assemblies, and agreement with an independent reader of the same models.
//
// Samples: CADNEXT_TEST_XT_DIR (kept outside the repository; SOURCES.txt there names each file's
// public repository and licence). Without it the test is skipped with code 77, never passed.
//
// Criteria, fixed before the first run and argued from the files themselves:
//
//   Geometry known by design (flow-around-sphere-v3.x_t, Onshape, Parasolid V33, text): a fluid
//   domain, a box of 0.1 m with a spherical cavity of radius r. Volume 0.001 - 4/3 pi r^3; the
//   exact faces integrated by OCCT's fixed Gauss rule, so the relative gap must stay <= 1e-7. (Its
//   adaptive mode is not used: on an elliptic extrusion it was 5.5e-9 off while reporting 1e-16.)
//   One solid with two shells: the cavity is a cavity, not a second lump.
//
//   Geometry known by design too (pipe_junction_model_tutorial.x_t, SimScale): a pipe of radius r
//   rising 1.2 m, two elbows of 45 degrees on tori of major radius R with a straight run of 0.2·√2 m
//   between them, and a branch of radius b along y at z = 0.5 from the pipe's wall to the plane
//   y = 0.4. Volume πr²(1.2 + 2R·π/4 + 0.2√2) + πb²·0.4 − ∫∫ √(r² − x²) over the branch's disk (the
//   wall it starts from). Same rule, same bound: 1e-7.
//
//   Not used as a reference, and why: the IGES files next to Base_Plate_Jig and ControlArm are other
//   revisions of those parts. The headers say so (ControlArm.IGS 2009-09-06 against ControlArm.x_t
//   2009-09-11; Base_Plate_Jig.IGS 2009-09-05, wireframe only, against the .x_t of 2009-09-26), and
//   the first comparison agreed: 42 faces against 34, areas 3 % apart. Likewise Bell_Crank.x_t and
//   .x_b are two revisions (26 and 27 faces, 2009-09-12 and 2009-09-21).
//
//   Assembly (Canard_Halves_1_Machineing_Asm.x_t, SOLIDWORKS 2016): one body instanced twice. The
//   product must keep one part with two occurrences, their placements equal to the transmitted
//   matrices (a rotation by 180 degrees to 1e-14, the translation bit for bit), and the .cadasm
//   written from it must link one part file twice.
//
//   Everything the reader does not support is refused with the reason; nothing is returned half
//   read. The known refusals are listed so that a change in them is seen.
#include "cadnext/assembly/AssemblySerializer.hpp"
#include "cadnext/gui/AssemblyStepExchange.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <BRep_Tool.hxx>
#include <GProp_GProps.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <algorithm>
#include <cmath>
#include <set>
#include <cstdio>
#include <string>
#include <vector>

using namespace cadnext;
using namespace cadnext::gui;


namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

QByteArray readAll(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return file.readAll();
}

bool decode(const QByteArray& bytes, ParasolidXtTopology& topology, QString& error) {
    return readParasolidXtFile(bytes, topology, error);
}

// The printable header and the data of a text file, the data joined into one record.
bool splitText(const QByteArray& file, QByteArray& header, QByteArray& data) {
    const qsizetype marker = file.indexOf("**END_OF_HEADER");
    const qsizetype end = marker < 0 ? -1 : file.indexOf('\n', marker);
    if (end < 0) return false;
    header = file.left(end + 1);
    data.clear();
    for (QByteArray record : file.mid(end + 1).split('\n')) {
        record.replace('\r', QByteArray());
        while (record.endsWith(' ')) record.chop(1);
        data.append(record);
    }
    return true;
}

struct Measured {
    int faces = 0;
    double area = 0.0;
    double volume = 0.0;
    bool closed = false;
    std::vector<gp_Pnt> vertices;
};

Measured measure(const TopoDS_Shape& shape) {
    Measured m;
    TopTools_IndexedMapOfShape faces, vertices;
    TopExp::MapShapes(shape, TopAbs_FACE, faces);
    TopExp::MapShapes(shape, TopAbs_VERTEX, vertices);
    m.faces = faces.Extent();
    for (int i = 1; i <= vertices.Extent(); ++i) m.vertices.push_back(BRep_Tool::Pnt(TopoDS::Vertex(vertices(i))));
    // OCCT's fixed Gauss rule; its adaptive mode misreports its own error (see the header).
    GProp_GProps surface;
    BRepGProp::SurfaceProperties(shape, surface);
    m.area = surface.Mass();
    TopExp_Explorer solid(shape, TopAbs_SOLID);
    if (solid.More()) {
        GProp_GProps volume;
        BRepGProp::VolumeProperties(shape, volume);
        m.volume = volume.Mass();
        m.closed = true;
    }
    return m;
}

void checkSphereDomain(const QString& directory) {
    const QString path = QDir(directory).filePath("flow-around-sphere-v3.x_t");
    ParasolidXtTopology topology;
    QString error;
    if (!decode(readAll(path), topology, error)) {
        check(false, "сфера: граф прочитан — " + error.toStdString());
        return;
    }
    double radius = 0.0;
    int spheres = 0;
    for (const auto& geometry : topology.analyticGeometry)
        if (geometry.type == 53) {
            radius = geometry.reals.value("radius");
            ++spheres;
        }
    std::printf("  сфера: радиус %.17g м, габарит вершин (%.17g %.17g %.17g)-(%.17g %.17g %.17g)\n", radius,
                topology.pointMin[0], topology.pointMin[1], topology.pointMin[2], topology.pointMax[0], topology.pointMax[1],
                topology.pointMax[2]);
    check(spheres == 1 && topology.pointMin == std::array<double, 3>{0, -0.05, -0.05} &&
              topology.pointMax == std::array<double, 3>{0.1, 0.05, 0.05},
          "сфера: один сферический узел, вершины куба ровно 0.1 м");
    kernel::OcctKernel kernel;
    kernel::ShapeHandle handle;
    if (!readParasolidXtAnalyticFile(path, kernel, handle, error)) {
        check(false, "сфера: точное тело — " + error.toStdString());
        return;
    }
    const TopoDS_Shape& shape = *kernel.findShape(handle);
    int solids = 0, shells = 0;
    for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) ++solids;
    for (TopExp_Explorer it(shape, TopAbs_SHELL); it.More(); it.Next()) ++shells;
    check(solids == 1 && shells == 2, "сфера: одно тело с двумя оболочками — полость, а не второй кусок");
    const double expected = 0.1 * 0.1 * 0.1 - 4.0 / 3.0 * M_PI * radius * radius * radius;
    const double volume = measure(shape).volume;
    const double gap = std::fabs(volume - expected) / expected;
    std::printf("  сфера: объём %.15g м3, по формуле %.15g, расхождение %.3g\n", volume, expected, gap);
    check(gap <= 1e-7, "сфера: объём области равен объёму куба без шара до 1e-7");
}

void checkPipeJunction(const QString& directory) {
    const QString path = QDir(directory).filePath("pipe_junction_model_tutorial.x_t");
    ParasolidXtTopology topology;
    QString error;
    if (!decode(readAll(path), topology, error)) {
        check(false, "труба: граф прочитан — " + error.toStdString());
        return;
    }
    // The radii as the file holds them: the pipe's and the branch's cylinders, the elbows' tori.
    std::set<double> cylinders, majors, minors;
    for (const auto& geometry : topology.analyticGeometry) {
        if (geometry.type == 51) cylinders.insert(geometry.reals.value("radius"));
        if (geometry.type == 54) {
            majors.insert(geometry.reals.value("major_radius"));
            minors.insert(geometry.reals.value("minor_radius"));
        }
    }
    check(cylinders == std::set<double>{0.05, 0.09} && majors == std::set<double>{0.25} && minors == std::set<double>{0.09},
          "труба: радиусы по замыслу — труба 0.09, отвод 0.05, колена на торах 0.25");
    kernel::OcctKernel kernel;
    kernel::ShapeHandle handle;
    if (!readParasolidXtAnalyticFile(path, kernel, handle, error)) {
        check(false, "труба: точное тело — " + error.toStdString());
        return;
    }
    const double r = 0.09, R = 0.25, b = 0.05;
    // ∫∫ √(r² − x²) over the disk of radius b, x = b·sin t: 2b²∫cos²t·√(r² − b²sin²t) dt (Simpson, smooth).
    const int n = 2000;
    double wall = 0.0;
    for (int i = 0; i <= n; ++i) {
        const double t = -M_PI / 2 + M_PI * i / n, weight = (i == 0 || i == n) ? 1 : (i % 2 ? 4 : 2);
        wall += weight * 2 * b * b * std::cos(t) * std::cos(t) * std::sqrt(r * r - b * b * std::sin(t) * std::sin(t));
    }
    wall *= M_PI / n / 3;
    const double expected = M_PI * r * r * (1.2 + 2 * R * M_PI / 4 + 0.2 * std::sqrt(2.0)) + M_PI * b * b * 0.4 - wall;
    const double volume = measure(*kernel.findShape(handle)).volume;
    const double gap = std::fabs(volume - expected) / expected;
    std::printf("  труба: объём %.15g м3, по формуле %.15g, расхождение %.3g\n", volume, expected, gap);
    check(gap <= 1e-7, "труба: объём равен объёму по замыслу до 1e-7");
}

void checkAssembly(const QString& directory) {
    const QString path = QDir(directory).filePath("Canard_Halves_1_Machineing_Asm.x_t");
    kernel::OcctKernel kernel;
    const auto read = readParasolidXtProduct(kernel, path.toStdString());
    check(read.isOk(), "Canard: сборка прочитана" + (read.isOk() ? std::string() : " — " + read.error().message));
    if (!read.isOk()) return;
    const kernel::ProductStructure& product = read.value();
    check(product.parts.size() == 1 && product.parts[0].name == "Canard_Half",
          "Canard: одна деталь «Canard_Half» (имя из атрибута SDL/TYSA_NAME)");
    check(product.assemblies.size() == 1 && product.assemblies[0].name == "Canard_Halves_1_Machineing_Asm",
          "Canard: одна сборка, названная по файлу (атрибут имени у сборки пуст)");
    check(parasolidXtProductIsAssembly(product), "Canard: распознана как сборка");
    if (product.assemblies.size() != 1 || product.assemblies[0].instances.size() != 2) {
        check(false, "Canard: два экземпляра");
        return;
    }
    const auto& first = product.assemblies[0].instances[0];
    const auto& second = product.assemblies[0].instances[1];
    check(first.definition == 0 && second.definition == 0 && !first.isAssembly && !second.isAssembly,
          "Canard: оба экземпляра ссылаются на одну деталь");
    // The transmitted matrices: diag(1,-1,-1) and diag(-1,1,-1), turns by 180° about x and about y,
    // with SOLIDWORKS' 1.5e-16 / 6.9e-15 off-diagonal noise.
    const auto near = [](const std::array<double, 4>& q, const std::array<double, 4>& e, double tolerance) {
        double gap = 0.0;
        for (int i = 0; i < 4; ++i) gap = std::max(gap, std::fabs(q[i] - e[i]));
        return gap <= tolerance;
    };
    check(near(first.placement.rotation, {0, 1, 0, 0}, 1e-14) && near(second.placement.rotation, {0, 0, 1, 0}, 1e-14),
          "Canard: повороты экземпляров — 180° вокруг x и вокруг y");
    const std::array<double, 3> t1{0.0025400000000000852, -0.0025400000000001099, -0.0025400000000000002};
    const std::array<double, 3> t2{0.043738389651752703, -0.069849999999999995, -0.0025400000000000002};
    check(first.placement.translation == t1 && second.placement.translation == t2,
          "Canard: переносы экземпляров равны переданным побитно");
    // Where the occurrence lands: the part's box turned and moved as the matrix says.
    const auto box = kernel.boundingBox(product.parts[0].shape);
    const auto placed = kernel.transformShape(product.parts[0].shape, kernel::placementMatrix(second.placement));
    const auto moved = placed.isOk() ? kernel.boundingBox(placed.value()) : decltype(box)::fail({ErrorCode::ShapeInvalid, "-"});
    if (box.isOk() && moved.isOk()) {
        const auto& b = box.value();
        // diag(-1, 1, -1): x and z flip, y stays.
        const double xMin = -b.max.x + t2[0], xMax = -b.min.x + t2[0];
        const double yMin = b.min.y + t2[1], yMax = b.max.y + t2[1];
        const double zMin = -b.max.z + t2[2], zMax = -b.min.z + t2[2];
        const auto& m = moved.value();
        const double gap = std::max({std::fabs(m.min.x - xMin), std::fabs(m.max.x - xMax), std::fabs(m.min.y - yMin),
                                     std::fabs(m.max.y - yMax), std::fabs(m.min.z - zMin), std::fabs(m.max.z - zMax)});
        std::printf("  габарит второго экземпляра против матрицы: %.3g m\n", gap);
        check(gap <= 1e-12, "Canard: второй экземпляр стоит там, куда его ставит матрица файла");
    } else {
        check(false, "Canard: габарит экземпляра");
    }

    QTemporaryDir folder;
    AssemblyExchangeReport report;
    const auto top = importParasolidXtAsAssembly(path.toStdString(), folder.path().toStdString(), report);
    check(top.isOk(), "Canard: записана как сборка CADNext" + (top.isOk() ? std::string() : " — " + top.error().message));
    if (!top.isOk()) return;
    check(report.parts == 1 && report.assemblies == 1 && report.occurrences == 2, "Canard: отчёт — 1 деталь, 1 сборка, 2 вхождения");
    const auto document = assembly::AssemblySerializer::loadFromFile(top.value());
    check(document.isOk() && document.value().components().size() == 2 &&
              document.value().components()[0].source.filePath == document.value().components()[1].source.filePath,
          "Canard: в .cadasm два компонента на один файл детали");
    check(QDir(folder.path()).entryList({"*.cadnext"}, QDir::Files).size() == 1, "Canard: файл детали записан один раз");
}

void checkEncodings(const QString& directory) {
    // A name with the V14 space compression \9 and a backslash escape, written into the text of a
    // real file: the declared length counts decoded characters.
    const QByteArray canard = readAll(QDir(directory).filePath("Canard_Halves_1_Machineing_Asm.x_t"));
    QByteArray header, data;
    check(splitText(canard, header, data), "текст: заголовок **END_OF_HEADER найден");
    const QByteArray original = "84 255 11 21 Canard_Half";
    check(data.contains(original), "текст: имя тела лежит строкой из 11 знаков");
    {
        QByteArray edited = data;
        edited.replace(original, "84 255 20 21 Canard\\9Half\\\\");
        ParasolidXtTopology topology;
        QString error;
        const bool ok = decode(header + edited, topology, error);
        bool named = false;
        for (const auto& attribute : topology.attributes)
            if (attribute.definition == "SDL/TYSA_NAME" && !attribute.strings.empty())
                named = named || attribute.strings.front() == QByteArray("Canard") + QByteArray(9, ' ') + "Half\\";
        check(ok && named, "текст: \\9 даёт девять пробелов, \\\\ — обратную косую черту");
    }
    {
        // Line breaks and trailing spaces of records carry no meaning (XT Format Reference, "Text").
        // Records are cut where Parasolid would cut them: never right after a separating space, which
        // the rule "trailing spaces are ignored" would otherwise swallow.
        QByteArray padded = header;
        for (qsizetype at = 0; at < data.size();) {
            qsizetype end = std::min(at + 37, data.size());
            while (end < data.size() && data[end - 1] == ' ') ++end;
            padded += data.mid(at, end - at) + "   \r\n";
            at = end;
        }
        ParasolidXtTopology a, b;
        QString error;
        const bool ok = decode(canard, a, error) && decode(padded, b, error);
        check(ok && a.nodeCount == b.nodeCount && a.faces.size() == b.faces.size() && a.pointMin == b.pointMin &&
                  a.pointMax == b.pointMax,
              "текст: другие переносы записей и хвостовые пробелы — тот же граф");
    }
    {
        // User fields follow every node in a layout the file does not describe: refused.
        QByteArray edited = data;
        const qsizetype at = edited.indexOf("_13006186 0 ");
        if (at > 0) edited.replace(at, 12, "_13006186 4 ");
        ParasolidXtTopology topology;
        QString error;
        check(at > 0 && !decode(header + edited, topology, error) && error.contains(QStringLiteral("пользовательские поля")),
              "текст: пользовательские поля — отказ с причиной");
    }
    {
        ParasolidXtTopology topology;
        QString error;
        const bool truncated = decode(canard.left(canard.size() * 2 / 3), topology, error);
        check(!truncated && !error.isEmpty() && topology.faces.empty(), "текст: обрезанный файл — отказ, ничего частичного");
        check(!decode(QByteArray("not a parasolid file"), topology, error) && error.contains(QStringLiteral("END_OF_HEADER")),
              "без заголовка — отказ с причиной");
        check(!decode(header + QByteArray("B\0\0", 3) + QByteArray(40, '\0'), topology, error) &&
                  error.contains(QStringLiteral("bare binary")),
              "«голый» двоичный формат (зависит от машины-писателя) — отказ с причиной");
    }
}

void checkKnownFiles(const QString& directory) {
    struct Expectation {
        const char* file;
        bool decodes;
        bool builds;
        const char* reason; // part of the refusal, when there is one
    };
    // The refusals are today's limits of the reader, kept visible.
    const Expectation expected[] = {
        {"Base_Plate_Jig.x_t", true, true, ""},
        {"Bell_Crank.x_t", true, true, ""},
        {"ControlArm.x_t", true, true, ""},
        {"Canard_Halves_1_Machineing_Asm.x_t", true, true, ""},
        {"Bell_Crank.x_b", true, true, ""},         // 'E' blends, one ending at a terminator
        {"LONGBAR.x_t", false, false, "до V14"},
        {"flow-around-sphere-v3.x_t", true, true, ""},
        {"pipe_junction_model_tutorial.x_t", true, true, ""},    // elbows between two meridians
    };
    for (const Expectation& e : expected) {
        const QString path = QDir(directory).filePath(e.file);
        ParasolidXtTopology topology;
        QString error;
        const bool decoded = decode(readAll(path), topology, error);
        kernel::OcctKernel kernel;
        const auto product = decoded ? readParasolidXtProduct(kernel, path.toStdString())
                                     : cadnext::Result<kernel::ProductStructure>::fail(
                                           {ErrorCode::SerializationFailed, error.toStdString()});
        const std::string reason = product.isOk() ? std::string() : product.error().message;
        std::printf("  %s: %s%s\n", e.file, decoded ? "граф прочитан" : "граф не прочитан",
                    reason.empty() ? ", тела построены" : (" — " + reason).c_str());
        check(decoded == e.decodes && product.isOk() == e.builds && (e.builds || reason.find(e.reason) != std::string::npos),
              std::string(e.file) + (e.builds ? ": точные тела" : ": отказ с причиной"));
        if (product.isOk()) {
            bool valid = true;
            for (const auto& part : product.value().parts) {
                const TopoDS_Shape* shape = kernel.findShape(part.shape);
                valid = valid && shape && BRepCheck_Analyzer(*shape).IsValid() && measure(*shape).volume > 0.0;
            }
            check(valid, std::string(e.file) + ": каждое тело проходит проверку BRep и имеет объём");
        }
    }
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString directory = qEnvironmentVariable("CADNEXT_TEST_XT_DIR");
    if (directory.isEmpty()) {
        std::printf("SKIP: CADNEXT_TEST_XT_DIR не задан\n");
        return 77;
    }
    checkKnownFiles(directory);
    checkEncodings(directory);
    checkSphereDomain(directory);
    checkPipeJunction(directory);
    checkAssembly(directory);
    std::printf("%s: %d failures\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
