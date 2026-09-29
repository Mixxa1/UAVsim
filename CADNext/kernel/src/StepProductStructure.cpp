#include "cadnext/kernel/StepProductStructure.hpp"

#include "cadnext/kernel/OcctKernel.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <functional>
#include <map>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRep_Builder.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Static.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPControl_StepModelType.hxx>
#include <Standard_Failure.hxx>
#include <TCollection_AsciiString.hxx>
#include <TCollection_ExtendedString.hxx>
#include <TDF_Label.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDF_Tool.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopExp.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shape.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_ColorType.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Quaternion.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>
#endif

namespace cadnext::kernel {

namespace {

// v rotated by the unit quaternion q (w, x, y, z).
std::array<double, 3> rotate(const std::array<double, 4>& q, const std::array<double, 3>& v) {
    const double w = q[0], x = q[1], y = q[2], z = q[3];
    const double tx = 2.0 * (y * v[2] - z * v[1]);
    const double ty = 2.0 * (z * v[0] - x * v[2]);
    const double tz = 2.0 * (x * v[1] - y * v[0]);
    return {v[0] + w * tx + (y * tz - z * ty), v[1] + w * ty + (z * tx - x * tz), v[2] + w * tz + (x * ty - y * tx)};
}

} // namespace

ProductPlacement composePlacements(const ProductPlacement& parent, const ProductPlacement& child) {
    const auto& a = parent.rotation;
    const auto& b = child.rotation;
    ProductPlacement result;
    result.rotation = {a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
                       a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
                       a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
                       a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]};
    const auto moved = rotate(parent.rotation, child.translation);
    for (int i = 0; i < 3; ++i) result.translation[i] = moved[i] + parent.translation[i];
    return result;
}

std::array<double, 16> placementMatrix(const ProductPlacement& placement) {
    const auto x = rotate(placement.rotation, {1.0, 0.0, 0.0});
    const auto y = rotate(placement.rotation, {0.0, 1.0, 0.0});
    const auto z = rotate(placement.rotation, {0.0, 0.0, 1.0});
    const auto& t = placement.translation;
    return {x[0], x[1], x[2], 0.0, y[0], y[1], y[2], 0.0, z[0], z[1], z[2], 0.0, t[0], t[1], t[2], 1.0};
}

std::string validateProductStructure(const ProductStructure& structure) {
    if (structure.assemblies.empty()) return "в структуре нет ни одной сборки";
    if (structure.root < 0 || structure.root >= static_cast<int>(structure.assemblies.size())) {
        return "корневая сборка указывает за пределы списка сборок";
    }
    for (std::size_t a = 0; a < structure.assemblies.size(); ++a) {
        for (const auto& instance : structure.assemblies[a].instances) {
            const int count = static_cast<int>(instance.isAssembly ? structure.assemblies.size() : structure.parts.size());
            if (instance.definition < 0 || instance.definition >= count) {
                return "экземпляр «" + instance.name + "» в сборке «" + structure.assemblies[a].name + "» ссылается на несуществующее определение";
            }
            const auto& q = instance.placement.rotation;
            const double norm = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
            if (!(std::fabs(norm - 1.0) <= 1e-9)) {
                return "положение экземпляра «" + instance.name + "» — не единичный кватернион, то есть не жёсткий поворот";
            }
        }
    }
    // An assembly that contains itself, directly or through others, has no finite product.
    std::vector<int> state(structure.assemblies.size(), 0); // 0 unseen, 1 on the path, 2 done
    std::string cycle;
    std::function<bool(int)> visit = [&](int a) {
        if (state[a] == 1) {
            cycle = structure.assemblies[a].name;
            return false;
        }
        if (state[a] == 2) return true;
        state[a] = 1;
        for (const auto& instance : structure.assemblies[a].instances)
            if (instance.isAssembly && !visit(instance.definition)) return false;
        state[a] = 2;
        return true;
    };
    if (!visit(structure.root)) return "сборка «" + cycle + "» содержит сама себя";
    return {};
}

#ifdef CADNEXT_WITH_OCCT

namespace {

using R = cadnext::Result<ProductStructure>;

// STEP files are in millimetres; the structure is in metres.
constexpr double kMillimetresPerMetre = 1000.0;

TopoDS_Shape scaled(const TopoDS_Shape& shape, double factor) {
    gp_Trsf scale;
    scale.SetScale(gp_Pnt(0.0, 0.0, 0.0), factor);
    return BRepBuilderAPI_Transform(shape, scale, true).Shape();
}

gp_Trsf toTrsf(const ProductPlacement& placement, double lengthScale) {
    gp_Trsf trsf;
    const auto& q = placement.rotation; // w, x, y, z
    trsf.SetRotation(gp_Quaternion(q[1], q[2], q[3], q[0]));
    trsf.SetTranslationPart(gp_Vec(placement.translation[0] * lengthScale, placement.translation[1] * lengthScale,
                                   placement.translation[2] * lengthScale));
    return trsf;
}

std::string utf8Name(const TDF_Label& label) {
    Handle(TDataStd_Name) attribute;
    if (!label.FindAttribute(TDataStd_Name::GetID(), attribute)) return {};
    const TCollection_ExtendedString& wide = attribute->Get();
    std::string utf8(static_cast<std::size_t>(wide.LengthOfCString()) + 1, '\0');
    char* buffer = utf8.data();
    wide.ToUTF8CString(buffer);
    utf8.resize(std::strlen(utf8.c_str()));
    return utf8;
}

void setName(const TDF_Label& label, const std::string& name) {
    if (!name.empty()) TDataStd_Name::Set(label, TCollection_ExtendedString(name.c_str(), Standard_True));
}

std::string entry(const TDF_Label& label) {
    TCollection_AsciiString text;
    TDF_Tool::Entry(label, text);
    return text.ToCString();
}

// OCCT may replace an occurrence name by the numeric STEP usage id or by a "=>[0:1:1:2]" reference,
// while the product keeps its real (possibly Cyrillic) name. Such a name says nothing to a user.
bool isGeneratedName(const std::string& name) {
    if (name.empty() || name.starts_with("=>")) return true;
    return std::all_of(name.begin(), name.end(), [](unsigned char c) { return std::isdigit(c); });
}

// Restores the global STEP writer schema when a write is done, whatever happened in between.
struct SchemaScope {
    TCollection_AsciiString previous;
    explicit SchemaScope(const char* schema) {
        if (const char* current = Interface_Static::CVal("write.step.schema")) previous = current;
        Interface_Static::SetCVal("write.step.schema", schema);
    }
    ~SchemaScope() {
        if (!previous.IsEmpty()) Interface_Static::SetCVal("write.step.schema", previous.ToCString());
    }
};

} // namespace

cadnext::Result<bool> writeStepProductStructure(OcctKernel& kernel, const ProductStructure& structure, const std::string& path,
                                                StepSchema schema) {
    using W = cadnext::Result<bool>;
    if (path.empty()) return W::fail({cadnext::ErrorCode::InvalidArgument, "не задан путь STEP"});
    if (const std::string problem = validateProductStructure(structure); !problem.empty()) {
        return W::fail({cadnext::ErrorCode::InvalidArgument, problem});
    }
    try {
        Handle(TDocStd_Document) document = new TDocStd_Document("BinXCAF");
        const Handle(XCAFDoc_ShapeTool) shapes = XCAFDoc_DocumentTool::ShapeTool(document->Main());
        const Handle(XCAFDoc_ColorTool) colours = XCAFDoc_DocumentTool::ColorTool(document->Main());

        // Every definition exists once. Parts first, then empty assemblies, then the instances that
        // link them: an instance can only point at a label that is already there.
        std::vector<TDF_Label> partLabels;
        for (const auto& part : structure.parts) {
            const TopoDS_Shape* source = kernel.findShape(part.shape);
            if (source == nullptr || source->IsNull()) {
                return W::fail({cadnext::ErrorCode::NotFound, "у детали «" + part.name + "» нет точной геометрии"});
            }
            const TDF_Label label = shapes->AddShape(scaled(*source, kMillimetresPerMetre), Standard_False);
            if (label.IsNull()) return W::fail({cadnext::ErrorCode::SerializationFailed, "не удалось добавить деталь «" + part.name + "»"});
            setName(label, part.name.empty() ? "Part" : part.name);
            if (part.colour) {
                const auto& c = *part.colour;
                colours->SetColor(label, Quantity_Color(c[0], c[1], c[2], Quantity_TOC_RGB), XCAFDoc_ColorSurf);
            }
            partLabels.push_back(label);
        }
        std::vector<TDF_Label> assemblyLabels;
        for (const auto& assembly : structure.assemblies) {
            TopoDS_Compound empty;
            BRep_Builder builder;
            builder.MakeCompound(empty);
            const TDF_Label label = shapes->AddShape(empty, Standard_True);
            if (label.IsNull() || !XCAFDoc_ShapeTool::IsAssembly(label)) {
                return W::fail({cadnext::ErrorCode::SerializationFailed, "не удалось создать сборку «" + assembly.name + "»"});
            }
            setName(label, assembly.name.empty() ? "Assembly" : assembly.name);
            assemblyLabels.push_back(label);
        }
        for (std::size_t a = 0; a < structure.assemblies.size(); ++a) {
            for (const auto& instance : structure.assemblies[a].instances) {
                const TDF_Label& definition = instance.isAssembly ? assemblyLabels[instance.definition] : partLabels[instance.definition];
                const TDF_Label component =
                    shapes->AddComponent(assemblyLabels[a], definition, TopLoc_Location(toTrsf(instance.placement, kMillimetresPerMetre)));
                if (component.IsNull()) {
                    return W::fail({cadnext::ErrorCode::SerializationFailed, "не удалось вставить «" + instance.name + "»"});
                }
                setName(component, instance.name);
            }
        }
        // Assemblies that are not the root and are used nowhere would become extra top-level
        // products in the file. They are part of the structure only if something reaches them.
        shapes->UpdateAssemblies();

        const SchemaScope scope(schema == StepSchema::AP242 ? "AP242DIS" : "AP214IS");
        STEPCAFControl_Writer writer;
        writer.SetNameMode(Standard_True);
        writer.SetColorMode(Standard_True);
        if (!writer.Transfer(document, STEPControl_AsIs) || writer.Write(path.c_str()) != IFSelect_RetDone) {
            return W::fail({cadnext::ErrorCode::SerializationFailed, "запись STEP не удалась"});
        }
        return W::ok(true);
    } catch (const Standard_Failure& failure) {
        return W::fail({cadnext::ErrorCode::SerializationFailed, std::string("запись STEP не удалась: ") + failure.GetMessageString()});
    }
}

cadnext::Result<ProductStructure> readStepProductStructure(OcctKernel& kernel, const std::string& path) {
    if (path.empty()) return R::fail({cadnext::ErrorCode::InvalidArgument, "не задан путь STEP"});
    try {
        Handle(TDocStd_Document) document = new TDocStd_Document("BinXCAF");
        STEPCAFControl_Reader reader;
        reader.SetNameMode(Standard_True);
        reader.SetColorMode(Standard_True);
        if (reader.ReadFile(path.c_str()) != IFSelect_RetDone || !reader.Transfer(document)) {
            return R::fail({cadnext::ErrorCode::SerializationFailed, "файл STEP не читается"});
        }
        const Handle(XCAFDoc_ShapeTool) shapes = XCAFDoc_DocumentTool::ShapeTool(document->Main());
        const Handle(XCAFDoc_ColorTool) colours = XCAFDoc_DocumentTool::ColorTool(document->Main());

        ProductStructure structure;
        std::map<std::string, int> partByLabel, assemblyByLabel;
        std::map<std::string, bool> skippedPart; // parts with no faces: construction or annotation geometry

        const auto colourOf = [&](const TDF_Label& label, const TopoDS_Shape& shape) -> std::optional<std::array<double, 3>> {
            Quantity_Color colour;
            for (const XCAFDoc_ColorType type : {XCAFDoc_ColorSurf, XCAFDoc_ColorGen}) {
                if (colours->GetColor(label, type, colour) || colours->GetColor(shape, type, colour)) {
                    return std::array<double, 3>{colour.Red(), colour.Green(), colour.Blue()};
                }
            }
            return std::nullopt;
        };

        // A part's geometry, in metres, restricted to what CADNext can hold as a body: its solids when
        // there are any (a product may bundle presentation curves with them), otherwise its faces.
        // A product without faces is construction geometry and is skipped, with its instances.
        const auto partShape = [&](const TopoDS_Shape& raw, std::string& problem) -> TopoDS_Shape {
            TopoDS_Shape shape = scaled(raw, 1.0 / kMillimetresPerMetre);
            if (shape.ShapeType() == TopAbs_COMPOUND) {
                TopTools_IndexedMapOfShape solids;
                TopExp::MapShapes(shape, TopAbs_SOLID, solids);
                if (solids.Extent() == 1) {
                    shape = solids(1);
                } else if (solids.Extent() > 1) {
                    TopoDS_Compound compound;
                    BRep_Builder builder;
                    builder.MakeCompound(compound);
                    for (Standard_Integer i = 1; i <= solids.Extent(); ++i) builder.Add(compound, solids(i));
                    shape = compound;
                }
            }
            TopTools_IndexedMapOfShape faces;
            TopExp::MapShapes(shape, TopAbs_FACE, faces);
            if (faces.IsEmpty()) return {};
            if (!BRepCheck_Analyzer(shape).IsValid()) problem = "геометрия не проходит проверку BRep";
            return shape;
        };

        std::function<int(const TDF_Label&, std::string&)> definePart;
        std::function<int(const TDF_Label&, std::string&)> defineAssembly;

        definePart = [&](const TDF_Label& label, std::string& error) -> int {
            const std::string key = entry(label);
            if (const auto found = partByLabel.find(key); found != partByLabel.end()) return found->second;
            if (skippedPart.count(key)) return -1;
            const TopoDS_Shape raw = XCAFDoc_ShapeTool::GetShape(label);
            if (raw.IsNull()) {
                error = "у изделия «" + utf8Name(label) + "» нет формы";
                return -2;
            }
            std::string problem;
            const TopoDS_Shape shape = partShape(raw, problem);
            if (shape.IsNull()) {
                skippedPart[key] = true;
                structure.warnings.push_back("изделие «" + utf8Name(label) + "» без граней (построения или аннотации) пропущено вместе со своими вхождениями");
                return -1;
            }
            if (!problem.empty()) {
                error = "деталь «" + utf8Name(label) + "»: " + problem;
                return -2;
            }
            ProductPart part;
            part.name = utf8Name(label);
            if (part.name.empty()) part.name = "Деталь " + std::to_string(structure.parts.size() + 1);
            part.shape = kernel.adoptShape(shape, "occt-step-part");
            part.colour = colourOf(label, raw);
            structure.parts.push_back(std::move(part));
            partByLabel[key] = static_cast<int>(structure.parts.size()) - 1;
            return partByLabel[key];
        };

        defineAssembly = [&](const TDF_Label& label, std::string& error) -> int {
            const std::string key = entry(label);
            if (const auto found = assemblyByLabel.find(key); found != assemblyByLabel.end()) return found->second;
            // Registered before its children, so a malformed file that contains itself stops here
            // instead of recursing forever; the validation below then names the cycle.
            const int index = static_cast<int>(structure.assemblies.size());
            structure.assemblies.push_back({utf8Name(label).empty() ? "Сборка " + std::to_string(index + 1) : utf8Name(label), {}});
            assemblyByLabel[key] = index;

            TDF_LabelSequence components;
            XCAFDoc_ShapeTool::GetComponents(label, components, Standard_False);
            for (Standard_Integer i = 1; i <= components.Length(); ++i) {
                const TDF_Label component = components.Value(i);
                TDF_Label referred;
                if (!XCAFDoc_ShapeTool::GetReferredShape(component, referred)) {
                    error = "вхождение в сборке «" + structure.assemblies[index].name + "» ни на что не ссылается";
                    return -2;
                }
                ProductInstance instance;
                instance.name = utf8Name(component);
                if (isGeneratedName(instance.name)) instance.name = utf8Name(referred);

                const gp_Trsf trsf = XCAFDoc_ShapeTool::GetLocation(component).Transformation();
                const bool rigid = std::fabs(trsf.ScaleFactor() - 1.0) <= 1e-12 && !trsf.IsNegative();
                if (XCAFDoc_ShapeTool::IsAssembly(referred)) {
                    if (!rigid) {
                        error = "подсборка «" + utf8Name(referred) + "» вставлена с отражением или масштабом — это не жёсткое положение";
                        return -2;
                    }
                    instance.isAssembly = true;
                    instance.definition = defineAssembly(referred, error);
                } else {
                    instance.definition = definePart(referred, error);
                    if (instance.definition >= 0 && !rigid) {
                        // A mirrored or scaled occurrence is a different shape: baked into a part of
                        // its own, placed at the identity, and said so.
                        const ProductPart& original = structure.parts[instance.definition];
                        const TopoDS_Shape* base = kernel.findShape(original.shape);
                        gp_Trsf inMetres = trsf;
                        inMetres.SetTranslationPart(trsf.TranslationPart() / kMillimetresPerMetre);
                        ProductPart baked = original;
                        baked.name = original.name + " (отражение)";
                        baked.shape = kernel.adoptShape(BRepBuilderAPI_Transform(*base, inMetres, true).Shape(), "occt-step-mirrored");
                        structure.parts.push_back(std::move(baked));
                        instance.definition = static_cast<int>(structure.parts.size()) - 1;
                        structure.warnings.push_back("вхождение «" + instance.name + "» с отражением или масштабом записано отдельной деталью");
                        structure.assemblies[index].instances.push_back(std::move(instance));
                        continue;
                    }
                }
                if (instance.definition == -2) return -2;
                if (instance.definition == -1) continue; // a skipped construction product
                gp_Quaternion rotation = trsf.GetRotation();
                rotation.Normalize();
                instance.placement.rotation = {rotation.W(), rotation.X(), rotation.Y(), rotation.Z()};
                const gp_XYZ t = trsf.TranslationPart() / kMillimetresPerMetre;
                instance.placement.translation = {t.X(), t.Y(), t.Z()};
                structure.assemblies[index].instances.push_back(std::move(instance));
            }
            return index;
        };

        TDF_LabelSequence roots;
        shapes->GetFreeShapes(roots);
        if (roots.IsEmpty()) return R::fail({cadnext::ErrorCode::SerializationFailed, "в файле STEP нет изделий"});
        std::string error;
        if (roots.Length() == 1 && XCAFDoc_ShapeTool::IsAssembly(roots.Value(1))) {
            structure.root = defineAssembly(roots.Value(1), error);
            if (structure.root < 0) return R::fail({cadnext::ErrorCode::SerializationFailed, error});
        } else {
            // A single part, or several top-level products: they become the members of one root
            // assembly at the identity, as the file places them.
            structure.assemblies.push_back({"Изделие", {}});
            structure.root = 0;
            for (Standard_Integer i = 1; i <= roots.Length(); ++i) {
                const TDF_Label label = roots.Value(i);
                ProductInstance instance;
                instance.name = utf8Name(label);
                if (XCAFDoc_ShapeTool::IsAssembly(label)) {
                    instance.isAssembly = true;
                    instance.definition = defineAssembly(label, error);
                } else {
                    instance.definition = definePart(label, error);
                }
                if (instance.definition == -2) return R::fail({cadnext::ErrorCode::SerializationFailed, error});
                if (instance.definition == -1) continue;
                structure.assemblies[0].instances.push_back(std::move(instance));
            }
            if (roots.Length() == 1 && !structure.parts.empty()) structure.assemblies[0].name = structure.parts[0].name;
        }
        if (structure.parts.empty()) return R::fail({cadnext::ErrorCode::SerializationFailed, "в файле STEP нет тел с гранями"});
        if (const std::string problem = validateProductStructure(structure); !problem.empty()) {
            return R::fail({cadnext::ErrorCode::SerializationFailed, problem});
        }
        return R::ok(std::move(structure));
    } catch (const Standard_Failure& failure) {
        return R::fail({cadnext::ErrorCode::SerializationFailed, std::string("чтение STEP не удалось: ") + failure.GetMessageString()});
    }
}

#else

cadnext::Result<ProductStructure> readStepProductStructure(OcctKernel&, const std::string&) {
    return cadnext::Result<ProductStructure>::fail({cadnext::ErrorCode::UnsupportedOperation, "STEP требует сборки с OCCT"});
}

cadnext::Result<bool> writeStepProductStructure(OcctKernel&, const ProductStructure&, const std::string&, StepSchema) {
    return cadnext::Result<bool>::fail({cadnext::ErrorCode::UnsupportedOperation, "STEP требует сборки с OCCT"});
}

#endif

} // namespace cadnext::kernel
