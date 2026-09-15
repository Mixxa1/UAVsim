#include "cadnext/cfd/FlowDomain.hpp"

#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBndLib.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <Bnd_Box.hxx>
#include <Standard_Failure.hxx>
#include <TopExp_Explorer.hxx>
#include <NCollection_DataMap.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS.hxx>

#include <algorithm>
#include <cmath>

namespace cadnext::cfd {

namespace {

Result<FlowDomain> failure(ErrorCode code, const std::string& message) {
    return Result<FlowDomain>::fail({code, message});
}

} // namespace

Result<FlowDomain> buildFlowDomain(kernel::OcctKernel& kernel, const std::vector<FlowBody>& bodies, const FlowDomainSettings& settings) {
    if (bodies.empty()) return failure(ErrorCode::InvalidArgument, "нет тел аппарата");
    if (!(settings.farfieldDistanceLengths > 0.0)) {
        return failure(ErrorCode::InvalidArgument, "не задано расстояние до границы дальнего поля");
    }

    std::vector<const TopoDS_Shape*> shapes;
    Bnd_Box bounds;
    for (const auto& body : bodies) {
        const TopoDS_Shape* shape = kernel.findShape(body.shape);
        if (shape == nullptr || shape->IsNull()) return failure(ErrorCode::NotFound, "нет геометрии тела " + body.id);
        // Exact bounds (no triangulation, no enlargement by tolerance).
        BRepBndLib::AddOptimal(*shape, bounds, Standard_False, Standard_False);
        shapes.push_back(shape);
    }
    double xmin, ymin, zmin, xmax, ymax, zmax;
    bounds.Get(xmin, ymin, zmin, xmax, ymax, zmax);

    FlowDomain result;
    result.boundsMin = {xmin, ymin, zmin};
    result.boundsMax = {xmax, ymax, zmax};
    result.referenceLengthM = std::max({xmax - xmin, ymax - ymin, zmax - zmin});
    if (!(result.referenceLengthM > 0.0)) return failure(ErrorCode::ShapeInvalid, "у аппарата нулевой размер");
    const double margin = settings.farfieldDistanceLengths * result.referenceLengthM;

    try {
        const TopoDS_Shape box =
            BRepPrimAPI_MakeBox(gp_Pnt(xmin - margin, ymin - margin, zmin - margin), gp_Pnt(xmax + margin, ymax + margin, zmax + margin)).Shape();
        TopTools_ListOfShape arguments, tools;
        arguments.Append(box);
        for (const TopoDS_Shape* shape : shapes) tools.Append(*shape);
        // One boolean with every body as a tool: the box minus their union, and a history that
        // follows each body face into the result.
        BRepAlgoAPI_Cut cut;
        cut.SetArguments(arguments);
        cut.SetTools(tools);
        cut.SetRunParallel(Standard_True);
        cut.Build();
        if (!cut.IsDone() || cut.HasErrors()) return failure(ErrorCode::KernelOperationFailed, "не удалось вырезать аппарат из расчётной области");
        const TopoDS_Shape domain = cut.Shape();

        // Kernel face numbering of the domain: explorer order, the same the mesher names faces by.
        // Faces are matched as the same face (geometry and placement), not by geometry alone: a
        // box's top and bottom can be one face placed twice.
        NCollection_DataMap<TopoDS_Shape, int, TopTools_ShapeMapHasher> domainIndex;
        int count = 0;
        for (TopExp_Explorer explorer(domain, TopAbs_FACE); explorer.More(); explorer.Next(), ++count) {
            domainIndex.Bind(explorer.Current(), count);
        }

        for (std::size_t b = 0; b < bodies.size(); ++b) {
            int bodyFace = 0;
            for (TopExp_Explorer explorer(*shapes[b], TopAbs_FACE); explorer.More(); explorer.Next(), ++bodyFace) {
                const TopoDS_Shape& face = explorer.Current();
                std::vector<int> found;
                auto take = [&](const TopoDS_Shape& candidate) {
                    if (const int* index = domainIndex.Seek(candidate)) found.push_back(*index);
                };
                if (!cut.IsDeleted(face)) {
                    const TopTools_ListOfShape& modified = cut.Modified(face);
                    if (modified.IsEmpty()) {
                        take(face);
                    } else {
                        for (TopTools_ListOfShape::Iterator it(modified); it.More(); it.Next()) take(it.Value());
                    }
                }
                const std::string faceId = "face-" + std::to_string(bodyFace);
                if (found.empty()) result.hiddenFaces.push_back({-1, bodies[b].id, faceId});
                for (int index : found) {
                    if (result.wallFaces.insert(index).second) result.walls.push_back({index, bodies[b].id, faceId});
                }
            }
        }
        if (result.wallFaces.empty()) return failure(ErrorCode::KernelOperationFailed, "в расчётной области не осталось стенок аппарата");
        std::sort(result.walls.begin(), result.walls.end(), [](const WallOrigin& a, const WallOrigin& c) { return a.domainFace < c.domainFace; });
        result.domain = kernel.adoptShape(domain, "flow-domain");
    } catch (const Standard_Failure& error) {
        return failure(ErrorCode::KernelOperationFailed, std::string("OCCT: ") + error.GetMessageString());
    }
    return Result<FlowDomain>::ok(std::move(result));
}

} // namespace cadnext::cfd
