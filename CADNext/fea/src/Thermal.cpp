#include "cadnext/fea/Thermal.hpp"

#include "cadnext/fea/TetElement.hpp"

#include "SystemAssembly.hpp"

#include <algorithm>
#include <array>
#include <functional>
#include <optional>
#include <cmath>
#include <map>
#include <memory>
#include <numeric>
#include <set>
#include <sstream>

namespace cadnext::fea {

namespace {

using detail::SparseCholesky;
using detail::SymmetricCsc;

template <typename T>
Result<T> failure(ErrorCode code, const std::string& message) {
    return Result<T>::fail({code, message});
}

// Everything a solve needs, assembled once: the free-DOF numbering, the linear part of the operator
// (conduction + convection) over the free DOFs with the fixed-temperature columns moved to the
// right-hand side, and the loads split by what can change in time.
struct ThermalSystem {
    const TetMesh* mesh = nullptr;
    int nodes = 0;
    std::vector<int> reduced;           // node → free index, −1 when fixed
    std::vector<double> fixedValue;     // per node (NaN when free)
    int free = 0;
    SymmetricCsc K;                     // conduction + convection, free × free
    SymmetricCsc C;                     // capacity, free × free (empty pattern values when steady)
    const ThermalProblem* problem = nullptr;
    bool transient = false;
    bool variable = false;              // temperature-dependent conductivity or specific heat
    std::vector<double> fFlux;          // face fluxes and equipment watts, free (independent of T)
    std::vector<double> fVolume;        // volume sources, free
    std::vector<double> f;              // sources − K_fc T_c, free
    std::vector<double> convectionFixed; // Σ h T∞ N dA with the problem's ambients, free
    std::vector<double> convectionPerK;  // Σ h N dA, for an ambient given in time, free
    std::vector<double> solarPerWm2;     // absorbed sunlight per unit irradiance, free
    std::vector<double> solarPerWm2Node; // the same per node (the heat balance needs the fixed ones too)
    double solarPerWm2W = 0.0;           // total absorbed per unit irradiance, m²
    double irradianceWm2 = 0.0;          // the problem's own
    // Radiation faces: per quadrature point of every face, the nodes, shape values, dA, ε, T_s.
    struct RadiationPoint {
        std::array<int, 6> nodes{};
        std::array<double, 6> shape{};
        int count = 0;
        double area = 0.0, emissivity = 0.0, surroundings = 0.0;
    };
    std::vector<RadiationPoint> radiation;
    // For the heat balance.
    double sourcesW = 0.0;
};

// One quadrature point of a boundary face: the face (element·4 + local face), its nodes and shape
// values, dA, the point and the outward unit normal.
struct FacePoint {
    long face = 0;
    std::array<int, 6> nodes{};
    const double* N = nullptr;
    int count = 0;
    double area = 0.0;
    Vec3 point, normal;
    double faceSize = 0.0; // √(face area), for offsets
};

std::optional<std::string> forEachFacePoint(const TetMesh& mesh, const std::string& group, const std::function<void(const FacePoint&)>& visit) {
    const auto found = mesh.faceGroups.find(group);
    if (found == mesh.faceGroups.end()) return "нет группы граней: " + group;
    const int faceNodeCount = mesh.order == ElementOrder::Quadratic ? 6 : 3;
    const auto& rule = triangleQuadratureDegree4();
    for (const auto& face : found->second) {
        const auto faceNodes = mesh.faceNodes(face);
        FacePoint p;
        p.face = static_cast<long>(face.element) * 4 + face.localFace;
        p.count = faceNodeCount;
        for (int n = 0; n < faceNodeCount; ++n) p.nodes[n] = faceNodes[n];
        double N[8][6];
        double dA[8];
        Vec3 x[8], normal[8];
        double faceArea = 0.0;
        for (std::size_t k = 0; k < rule.size(); ++k) {
            double dS[6], dT[6];
            triangleShapeFunctions(mesh.order, rule[k].s, rule[k].t, N[k], dS, dT);
            Vec3 xs, xt, at;
            for (int n = 0; n < faceNodeCount; ++n) {
                xs += mesh.nodes[p.nodes[n]] * dS[n];
                xt += mesh.nodes[p.nodes[n]] * dT[n];
                at += mesh.nodes[p.nodes[n]] * N[k][n];
            }
            const Vec3 areaNormal = cross(xs, xt); // outward (corners counter-clockwise seen from outside)
            const double size = length(areaNormal);
            dA[k] = size * rule[k].weight;
            x[k] = at;
            normal[k] = size > 0.0 ? areaNormal * (1.0 / size) : Vec3{};
            faceArea += dA[k];
        }
        p.faceSize = std::sqrt(faceArea);
        for (std::size_t k = 0; k < rule.size(); ++k) {
            p.N = N[k];
            p.area = dA[k];
            p.point = x[k];
            p.normal = normal[k];
            visit(p);
        }
    }
    return std::nullopt;
}

std::optional<std::string> faceIntegrate(const TetMesh& mesh, const std::string& group,
                                         const std::function<void(const std::array<int, 6>&, const double*, int, double)>& atPoint) {
    return forEachFacePoint(mesh, group, [&](const FacePoint& p) { atPoint(p.nodes, p.N, p.count, p.area); });
}

double faceArea(const TetMesh& mesh, const std::string& group) {
    double area = 0.0;
    faceIntegrate(mesh, group, [&](const std::array<int, 6>&, const double*, int, double dA) { area += dA; });
    return area;
}

// --- Shading. The boundary of the mesh (faces of one element only, found from the connectivity, not
// from the face groups, which need not cover it) as flat triangles — a six-node face as its four — binned
// on a grid in the plane normal to the rays: a ray parallel to the sun only meets triangles whose
// projection covers its own, so one cell is all it has to test.
class Occluders {
public:
    Occluders(const TetMesh& mesh, const Vec3& towardSun) : s_(towardSun) {
        const Vec3 a = std::fabs(s_.x) < 0.9 ? Vec3{1.0, 0.0, 0.0} : Vec3{0.0, 1.0, 0.0};
        u_ = cross(s_, a);
        u_ = u_ * (1.0 / length(u_));
        v_ = cross(s_, u_);
        struct Keyed {
            std::array<int, 3> key;
            BoundaryFace face;
        };
        std::vector<Keyed> all;
        all.reserve(mesh.elements.size() * 4);
        for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
            for (int k = 0; k < 4; ++k) {
                std::array<int, 3> key{mesh.elements[e][kTetFaces[k][0]], mesh.elements[e][kTetFaces[k][1]], mesh.elements[e][kTetFaces[k][2]]};
                std::sort(key.begin(), key.end());
                all.push_back({key, {e, k}});
            }
        }
        std::sort(all.begin(), all.end(), [](const Keyed& l, const Keyed& r) { return l.key < r.key; });
        for (std::size_t i = 0; i < all.size();) {
            std::size_t j = i + 1;
            while (j < all.size() && all[j].key == all[i].key) ++j;
            if (j - i == 1) addFace(mesh, all[i].face);
            i = j;
        }
        // Grid: about one triangle per cell.
        double uMin = 1e300, uMax = -1e300, vMin = 1e300, vMax = -1e300;
        for (const auto& t : triangles_)
            for (const auto& p : t) {
                uMin = std::min(uMin, dot(p, u_)), uMax = std::max(uMax, dot(p, u_));
                vMin = std::min(vMin, dot(p, v_)), vMax = std::max(vMax, dot(p, v_));
            }
        const double width = std::max(uMax - uMin, 1e-12), height = std::max(vMax - vMin, 1e-12);
        cell_ = std::max(std::sqrt(width * height / std::max<std::size_t>(1, triangles_.size())), 1e-12);
        nu_ = std::clamp(static_cast<int>(std::ceil(width / cell_)), 1, 2048);
        nv_ = std::clamp(static_cast<int>(std::ceil(height / cell_)), 1, 2048);
        cellU_ = width / nu_;
        cellV_ = height / nv_;
        u0_ = uMin, v0_ = vMin;
        cells_.assign(static_cast<std::size_t>(nu_) * nv_, {});
        for (int t = 0; t < static_cast<int>(triangles_.size()); ++t) {
            double a0 = 1e300, a1 = -1e300, b0 = 1e300, b1 = -1e300;
            for (const auto& p : triangles_[t]) {
                a0 = std::min(a0, dot(p, u_)), a1 = std::max(a1, dot(p, u_));
                b0 = std::min(b0, dot(p, v_)), b1 = std::max(b1, dot(p, v_));
            }
            for (int i = cellU(a0); i <= cellU(a1); ++i)
                for (int j = cellV(b0); j <= cellV(b1); ++j) cells_[static_cast<std::size_t>(i) * nv_ + j].push_back(t);
        }
    }

    // Does a ray from `origin` towards the sun meet the boundary (other than the face `ownFace`)?
    bool blocked(const Vec3& origin, long ownFace) const {
        const int i = cellU(dot(origin, u_)), j = cellV(dot(origin, v_));
        for (int t : cells_[static_cast<std::size_t>(i) * nv_ + j]) {
            if (owner_[t] == ownFace) continue;
            // Möller–Trumbore.
            const auto& tri = triangles_[t];
            const Vec3 e1 = tri[1] - tri[0], e2 = tri[2] - tri[0];
            const Vec3 p = cross(s_, e2);
            const double det = dot(e1, p);
            if (std::fabs(det) <= 1e-14 * length(e1) * length(e2)) continue; // parallel to the rays
            const double inv = 1.0 / det;
            const Vec3 d = origin - tri[0];
            const double a = dot(d, p) * inv;
            if (a < 0.0 || a > 1.0) continue;
            const Vec3 q = cross(d, e1);
            const double b = dot(s_, q) * inv;
            if (b < 0.0 || a + b > 1.0) continue;
            if (dot(e2, q) * inv > 0.0) return true;
        }
        return false;
    }

private:
    void addFace(const TetMesh& mesh, const BoundaryFace& face) {
        const auto n = mesh.faceNodes(face);
        const long id = static_cast<long>(face.element) * 4 + face.localFace;
        auto add = [&](int a, int b, int c) {
            triangles_.push_back({mesh.nodes[n[a]], mesh.nodes[n[b]], mesh.nodes[n[c]]});
            owner_.push_back(id);
        };
        if (n.size() == 6) {
            add(0, 3, 5), add(3, 1, 4), add(5, 4, 2), add(3, 4, 5);
        } else {
            add(0, 1, 2);
        }
    }
    int cellU(double value) const { return std::clamp(static_cast<int>(std::floor((value - u0_) / cellU_)), 0, nu_ - 1); }
    int cellV(double value) const { return std::clamp(static_cast<int>(std::floor((value - v0_) / cellV_)), 0, nv_ - 1); }

    Vec3 s_, u_, v_;
    std::vector<std::array<Vec3, 3>> triangles_;
    std::vector<long> owner_;
    double u0_ = 0.0, v0_ = 0.0, cell_ = 1.0, cellU_ = 1.0, cellV_ = 1.0;
    int nu_ = 1, nv_ = 1;
    std::vector<std::vector<int>> cells_;
};

std::optional<std::string> checkSunlight(const Sunlight& sun) {
    if (!(length(sun.towardSun) > 0.0)) return std::string("солнце: не задано направление");
    if (!(sun.absorptance > 0.0 && sun.absorptance <= 1.0)) return std::string("солнце: поглощательная способность 0 < α ≤ 1");
    if (!(sun.irradianceWm2 >= 0.0)) return std::string("солнце: облучённость не может быть отрицательной");
    return std::nullopt;
}

std::vector<std::string> sunlitGroups(const TetMesh& mesh, const Sunlight& sun) {
    std::set<std::string> names(sun.faceGroups.begin(), sun.faceGroups.end());
    if (names.empty())
        for (const auto& [name, faces] : mesh.faceGroups) names.insert(name);
    return {names.begin(), names.end()};
}

// Every sunlit quadrature point of the sunlight's faces: α max(0, n·s) and whether it is shaded.
std::optional<std::string> forEachSunPoint(const TetMesh& mesh, const Sunlight& sun,
                                           const std::function<void(const FacePoint&, double cosine, bool shaded)>& visit) {
    if (const auto message = checkSunlight(sun)) return message;
    const Vec3 s = sun.towardSun * (1.0 / length(sun.towardSun));
    const Occluders occluders(mesh, s);
    for (const auto& group : sunlitGroups(mesh, sun)) {
        const auto message = forEachFacePoint(mesh, group, [&](const FacePoint& p) {
            const double cosine = dot(p.normal, s);
            if (!(cosine > 0.0)) return;
            // Just off the surface, so the neighbouring flat triangles of a curved face are not hit at
            // distance zero.
            visit(p, cosine, occluders.blocked(p.point + p.normal * (1e-3 * p.faceSize), p.face));
        });
        if (message) return message;
    }
    return std::nullopt;
}

void fill(ThermalSystem& system, const std::vector<double>* field);

std::optional<std::string> assemble(const ThermalProblem& problem, bool transient, ThermalSystem& system) {
    if (problem.mesh == nullptr || problem.mesh->elements.empty()) return std::string("пустая сетка");
    const auto& props = problem.material;
    if (!(props.conductivityWmK > 0.0) && !props.conductivityOf) return std::string("нет теплопроводности материала");
    if (transient && !(props.densityKgM3 > 0.0 && (props.specificHeatJkgK > 0.0 || props.specificHeatOf))) {
        return std::string("нет плотности или теплоёмкости материала");
    }
    const TetMesh& mesh = *problem.mesh;
    if (const auto message = detail::checkElementNodes(mesh)) return message;
    if (const auto invalid = detail::firstInvalidElement(mesh)) {
        std::ostringstream message;
        message << "вырожденный, вывернутый или сложенный элемент " << invalid->first;
        return message.str();
    }
    system.mesh = &mesh;
    system.problem = &problem;
    system.transient = transient;
    system.variable = static_cast<bool>(props.conductivityOf) || (transient && static_cast<bool>(props.specificHeatOf));
    system.nodes = static_cast<int>(mesh.nodes.size());
    system.fixedValue.assign(system.nodes, std::nan(""));
    for (const auto& fixed : problem.fixed) {
        if (!(fixed.temperatureK > 0.0)) return std::string("заданная температура должна быть в кельвинах, > 0");
        if (mesh.faceGroups.count(fixed.faceGroup) == 0) return "нет группы граней: " + fixed.faceGroup;
        for (int node : mesh.nodesOnGroup(fixed.faceGroup)) {
            if (!std::isnan(system.fixedValue[node]) && system.fixedValue[node] != fixed.temperatureK) {
                return "на узле сходятся две разные заданные температуры (грань " + fixed.faceGroup + ")";
            }
            system.fixedValue[node] = fixed.temperatureK;
        }
    }
    system.reduced.assign(system.nodes, -1);
    for (int node = 0; node < system.nodes; ++node)
        if (std::isnan(system.fixedValue[node])) system.reduced[node] = system.free++;
    if (system.free == 0) return std::string("все температуры заданы — считать нечего");
    for (const auto& c : problem.convection)
        if (!(c.coefficientWm2K >= 0.0 && c.ambientK > 0.0)) return std::string("конвекция: h ≥ 0, температура среды в кельвинах");
    for (const auto& r : problem.radiation)
        if (!(r.emissivity > 0.0 && r.emissivity <= 1.0 && r.surroundingsK > 0.0)) return std::string("излучение: 0 < ε ≤ 1, температура окружения в кельвинах");

    // Sparsity over free DOFs: element couplings and face couplings are both within elements.
    std::vector<std::vector<int>> columns(system.free);
    const int perElement = mesh.nodesPerElement();
    for (const auto& element : mesh.elements) {
        for (int a = 0; a < perElement; ++a) {
            const int ra = system.reduced[element[a]];
            if (ra < 0) continue;
            for (int b = 0; b < perElement; ++b) {
                const int rb = system.reduced[element[b]];
                if (rb < 0 || ra > rb) continue;
                columns[rb].push_back(ra);
            }
        }
    }
    SymmetricCsc& K = system.K;
    K.size = system.free;
    K.columnStarts.assign(system.free + 1, 0);
    for (int c = 0; c < system.free; ++c) {
        auto& rows = columns[c];
        std::sort(rows.begin(), rows.end());
        rows.erase(std::unique(rows.begin(), rows.end()), rows.end());
        K.columnStarts[c + 1] = K.columnStarts[c] + static_cast<long>(rows.size());
    }
    K.rowIndices.reserve(K.columnStarts.back());
    for (const auto& rows : columns) K.rowIndices.insert(K.rowIndices.end(), rows.begin(), rows.end());
    K.values.assign(K.rowIndices.size(), 0.0);
    if (transient) system.C = K;
    system.f.assign(system.free, 0.0);
    system.convectionFixed.assign(system.free, 0.0);
    system.convectionPerK.assign(system.free, 0.0);
    system.solarPerWm2.assign(system.free, 0.0);
    system.solarPerWm2Node.assign(system.nodes, 0.0);

    system.fFlux.assign(system.free, 0.0);
    system.fVolume.assign(system.free, 0.0);
    std::vector<double> source;
    if (!problem.volumetricHeatPerElementWm3.empty() && problem.volumetricHeatPerElementWm3.size() != mesh.elements.size()) {
        return std::string("поэлементный источник тепла не совпадает с сеткой");
    }
    if (problem.volumetricHeatWm3 != 0.0 || !problem.volumetricHeatPerElementWm3.empty()) {
        for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
            const int* nodes = mesh.elements[e].data();
            const double density = problem.volumetricHeatWm3
                                   + (problem.volumetricHeatPerElementWm3.empty() ? 0.0 : problem.volumetricHeatPerElementWm3[e]);
            if (density == 0.0) continue;
            tetScalarSource(mesh, e, density, source);
            for (int a = 0; a < perElement; ++a) {
                if (system.reduced[nodes[a]] >= 0) system.fVolume[system.reduced[nodes[a]]] += source[a];
                system.sourcesW += source[a];
            }
        }
    }
    for (const auto& c : problem.convection)
        if (mesh.faceGroups.count(c.faceGroup) == 0) return "нет группы граней: " + c.faceGroup;
    auto addFlux = [&](const std::string& group, double flux) {
        return faceIntegrate(mesh, group, [&](const std::array<int, 6>& nodes, const double* N, int count, double dA) {
            for (int a = 0; a < count; ++a) {
                if (system.reduced[nodes[a]] >= 0) system.fFlux[system.reduced[nodes[a]]] += flux * N[a] * dA;
                system.sourcesW += flux * N[a] * dA;
            }
        });
    };
    for (const auto& q : problem.fluxes)
        if (const auto message = addFlux(q.faceGroup, q.fluxWm2)) return message;
    for (const auto& load : problem.heatLoads) {
        const double area = faceArea(mesh, load.faceGroup);
        if (!(area > 0.0)) return "нет группы граней или нулевая площадь: " + load.faceGroup;
        if (const auto message = addFlux(load.faceGroup, load.watts / area)) return message;
    }
    if (problem.sunlight) {
        system.irradianceWm2 = problem.sunlight->irradianceWm2;
        const double alpha = problem.sunlight->absorptance;
        const auto message = forEachSunPoint(mesh, *problem.sunlight, [&](const FacePoint& p, double cosine, bool shaded) {
            if (shaded) return;
            const double perWm2 = alpha * cosine * p.area;
            system.solarPerWm2W += perWm2;
            for (int a = 0; a < p.count; ++a) {
                system.solarPerWm2Node[p.nodes[a]] += perWm2 * p.N[a];
                if (system.reduced[p.nodes[a]] >= 0) system.solarPerWm2[system.reduced[p.nodes[a]]] += perWm2 * p.N[a];
            }
        });
        if (message) return message;
    }
    for (const auto& r : problem.radiation) {
        const auto message = faceIntegrate(mesh, r.faceGroup, [&](const std::array<int, 6>& nodes, const double* N, int count, double dA) {
            ThermalSystem::RadiationPoint point;
            point.nodes = nodes;
            point.count = count;
            for (int a = 0; a < count; ++a) point.shape[a] = N[a];
            point.area = dA;
            point.emissivity = r.emissivity;
            point.surroundings = r.surroundingsK;
            system.radiation.push_back(point);
        });
        if (message) return message;
    }
    // Constant properties: the operators once and for all. Temperature-dependent ones are filled by the
    // solver at the temperatures it iterates on.
    if (!system.variable) fill(system, nullptr);
    return std::nullopt;
}

// The operators: conduction and convection into K (the fixed columns moved to f), capacity into C.
// With temperature-dependent properties `field` (per node) is where they are evaluated; refilled every
// time the field moves.
void fill(ThermalSystem& system, const std::vector<double>* field) {
    const TetMesh& mesh = *system.mesh;
    const ThermalProblem& problem = *system.problem;
    const auto& props = problem.material;
    const int perElement = mesh.nodesPerElement();
    std::fill(system.K.values.begin(), system.K.values.end(), 0.0);
    if (system.transient) std::fill(system.C.values.begin(), system.C.values.end(), 0.0);
    system.f.assign(system.free, 0.0);
    std::fill(system.convectionFixed.begin(), system.convectionFixed.end(), 0.0);
    std::fill(system.convectionPerK.begin(), system.convectionPerK.end(), 0.0);
    auto scatter = [&](const int* nodes, int count, const std::vector<double>& matrix, SymmetricCsc& target, bool moveFixed) {
        for (int a = 0; a < count; ++a) {
            const int ra = system.reduced[nodes[a]];
            if (ra < 0) continue;
            for (int b = 0; b < count; ++b) {
                const double value = matrix[static_cast<std::size_t>(a) * count + b];
                const int rb = system.reduced[nodes[b]];
                if (rb >= 0) {
                    if (ra <= rb) target.at(ra, rb) += value;
                } else if (moveFixed) {
                    system.f[ra] -= value * system.fixedValue[nodes[b]];
                }
            }
        }
    };
    const std::function<double(double)> capacityOf = props.specificHeatOf
                                                         ? std::function<double(double)>([&](double T) { return props.densityKgM3 * props.specificHeatOf(T); })
                                                         : std::function<double(double)>();
    std::vector<double> local;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        const int* nodes = mesh.elements[e].data();
        if (props.conductivityOf && field) tetConductivity(mesh, e, props.conductivityOf, *field, local);
        else tetConductivity(mesh, e, props.conductivityWmK, local);
        scatter(nodes, perElement, local, system.K, true);
        if (system.transient) {
            if (capacityOf && field) tetCapacity(mesh, e, capacityOf, *field, local);
            else tetCapacity(mesh, e, props.densityKgM3 * props.specificHeatJkgK, local);
            scatter(nodes, perElement, local, system.C, false);
        }
    }
    for (const auto& c : problem.convection) {
        faceIntegrate(mesh, c.faceGroup, [&](const std::array<int, 6>& nodes, const double* N, int count, double dA) {
            std::vector<double> m(static_cast<std::size_t>(count) * count);
            for (int a = 0; a < count; ++a)
                for (int b = 0; b < count; ++b) m[static_cast<std::size_t>(a) * count + b] = c.coefficientWm2K * N[a] * N[b] * dA;
            scatter(nodes.data(), count, m, system.K, true);
            for (int a = 0; a < count; ++a) {
                const int ra = system.reduced[nodes[a]];
                if (ra < 0) continue;
                system.convectionFixed[ra] += c.coefficientWm2K * c.ambientK * N[a] * dA;
                system.convectionPerK[ra] += c.coefficientWm2K * N[a] * dA;
            }
        });
    }
}

std::vector<double> fullField(const ThermalSystem& system, const std::vector<double>& freeValues) {
    std::vector<double> T(system.nodes);
    for (int node = 0; node < system.nodes; ++node)
        T[node] = system.reduced[node] >= 0 ? freeValues[system.reduced[node]] : system.fixedValue[node];
    return T;
}

// Radiation: its contribution to the residual (heat LEAVING, εσ(T⁴ − T_s⁴)) and, when `tangent` is
// given, 4εσT³ N Nᵀ added to it. `surroundings`, when given, replaces every point's own.
void radiationTerms(const ThermalSystem& system, const std::vector<double>& T, std::vector<double>& residual, SymmetricCsc* tangent,
                    const double* surroundings = nullptr) {
    for (const auto& p : system.radiation) {
        double t = 0.0;
        for (int a = 0; a < p.count; ++a) t += p.shape[a] * T[p.nodes[a]];
        const double ts = surroundings ? *surroundings : p.surroundings;
        const double out = p.emissivity * kStefanBoltzmann * (t * t * t * t - ts * ts * ts * ts) * p.area;
        const double slope = 4.0 * p.emissivity * kStefanBoltzmann * t * t * t * p.area;
        for (int a = 0; a < p.count; ++a) {
            const int ra = system.reduced[p.nodes[a]];
            if (ra < 0) continue;
            residual[ra] += out * p.shape[a];
            if (!tangent) continue;
            for (int b = 0; b < p.count; ++b) {
                const int rb = system.reduced[p.nodes[b]];
                if (rb >= 0 && ra <= rb) tangent->at(ra, rb) += slope * p.shape[a] * p.shape[b];
            }
        }
    }
}

// Heat balance of a steady field: everything that enters (sources, sunlight, convection and radiation
// gains) against what leaves (convection, radiation, fixed faces), from element-level operators.
double heatBalance(const ThermalProblem& problem, const ThermalSystem& system, const std::vector<double>& T) {
    const TetMesh& mesh = *system.mesh;
    const double solarW = system.irradianceWm2 * system.solarPerWm2W;
    double supplied = 0.0, convective = 0.0, radiative = 0.0, magnitude = std::fabs(system.sourcesW) + std::fabs(solarW);
    // Heat through fixed faces = reaction of the conduction operator (with sources) at fixed nodes.
    std::vector<double> reaction(system.nodes, 0.0), local, source;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        const auto& element = mesh.elements[e];
        const int count = mesh.nodesPerElement();
        if (problem.material.conductivityOf) tetConductivity(mesh, e, problem.material.conductivityOf, T, local);
        else tetConductivity(mesh, e, problem.material.conductivityWmK, local);
        for (int a = 0; a < count; ++a)
            for (int b = 0; b < count; ++b) reaction[element[a]] += local[static_cast<std::size_t>(a) * count + b] * T[element[b]];
        const double density = problem.volumetricHeatWm3
                               + (problem.volumetricHeatPerElementWm3.empty() ? 0.0 : problem.volumetricHeatPerElementWm3[e]);
        if (density != 0.0) {
            tetScalarSource(mesh, e, density, source);
            for (int a = 0; a < count; ++a) reaction[element[a]] -= source[a];
        }
    }
    for (const auto& c : problem.convection)
        faceIntegrate(mesh, c.faceGroup, [&](const std::array<int, 6>& nodes, const double* N, int count, double dA) {
            double t = 0.0;
            for (int a = 0; a < count; ++a) t += N[a] * T[nodes[a]];
            const double q = c.coefficientWm2K * (t - c.ambientK) * dA;
            convective += q;
            magnitude += std::fabs(q);
            for (int a = 0; a < count; ++a) reaction[nodes[a]] += q * N[a];
        });
    for (const auto& p : system.radiation) {
        double t = 0.0;
        for (int a = 0; a < p.count; ++a) t += p.shape[a] * T[p.nodes[a]];
        const double q = p.emissivity * kStefanBoltzmann * (std::pow(t, 4) - std::pow(p.surroundings, 4)) * p.area;
        radiative += q;
        magnitude += std::fabs(q);
        for (int a = 0; a < p.count; ++a) reaction[p.nodes[a]] += q * p.shape[a];
    }
    for (const auto& q : problem.fluxes)
        faceIntegrate(mesh, q.faceGroup, [&](const std::array<int, 6>& nodes, const double* N, int count, double dA) {
            for (int a = 0; a < count; ++a) reaction[nodes[a]] -= q.fluxWm2 * N[a] * dA;
        });
    for (const auto& load : problem.heatLoads) {
        const double area = faceArea(mesh, load.faceGroup);
        faceIntegrate(mesh, load.faceGroup, [&](const std::array<int, 6>& nodes, const double* N, int count, double dA) {
            for (int a = 0; a < count; ++a) reaction[nodes[a]] -= load.watts / area * N[a] * dA;
        });
    }
    for (int node = 0; node < system.nodes; ++node) reaction[node] -= system.irradianceWm2 * system.solarPerWm2Node[node];
    // At a fixed node the equation's residual is the heat the constraint supplies; what leaves through
    // the fixed faces is minus their sum. The scale is the sum of the magnitudes — heat entering one
    // fixed face and leaving another nets to zero and would divide by nothing.
    for (int node = 0; node < system.nodes; ++node) {
        if (system.reduced[node] >= 0) continue;
        supplied += reaction[node];
        magnitude += std::fabs(reaction[node]);
    }
    // Sources = convective + radiative + through the fixed faces (all as heat leaving).
    const double imbalance = system.sourcesW + solarW - convective - radiative + supplied;
    return magnitude > 0.0 ? std::fabs(imbalance) / magnitude : 0.0;
}

} // namespace

Result<SolarExposure> solarExposure(const TetMesh& mesh, const Sunlight& sunlight) {
    SolarExposure exposure;
    const auto message = forEachSunPoint(mesh, sunlight, [&](const FacePoint& p, double cosine, bool shaded) {
        if (shaded) {
            exposure.shadedAreaM2 += p.area;
            return;
        }
        exposure.sunlitProjectedAreaM2 += cosine * p.area;
    });
    if (message) return failure<SolarExposure>(ErrorCode::InvalidArgument, *message);
    exposure.absorbedW = sunlight.absorptance * sunlight.irradianceWm2 * exposure.sunlitProjectedAreaM2;
    return Result<SolarExposure>::ok(exposure);
}

Result<ThermalSolution> solveSteadyThermal(const ThermalProblem& problem, const ThermalSettings& settings) {
    ThermalSystem system;
    if (const auto message = assemble(problem, false, system)) return failure<ThermalSolution>(ErrorCode::InvalidArgument, *message);
    if (problem.fixed.empty() && problem.convection.empty() && problem.radiation.empty()) {
        return failure<ThermalSolution>(ErrorCode::InvalidArgument, "тепло некуда отводить: нужна заданная температура, конвекция или излучение");
    }
    std::vector<double> load(system.free);
    auto computeLoad = [&]() {
        for (int i = 0; i < system.free; ++i) {
            load[i] = system.f[i] + system.fFlux[i] + system.fVolume[i] + system.convectionFixed[i] + system.irradianceWm2 * system.solarPerWm2[i];
        }
    };
    if (!system.variable) computeLoad();
    ThermalSolution solution;
    // Linear start (radiation linearised at the surroundings), then Newton on the full residual.
    std::vector<double> T(system.free, 0.0);
    {
        double start = 0.0;
        int count = 0;
        for (const auto& r : problem.radiation) start += r.surroundingsK, ++count;
        for (const auto& c : problem.convection) start += c.ambientK, ++count;
        for (const auto& f : problem.fixed) start += f.temperatureK, ++count;
        std::fill(T.begin(), T.end(), count > 0 ? start / count : 293.15);
    }
    for (int iteration = 0; iteration < settings.maximumNewtonIterations; ++iteration) {
        const auto full = fullField(system, T);
        // Temperature-dependent conductivity: the operator at the current field (a Picard step for k(T),
        // Newton's for the radiation).
        if (system.variable) {
            fill(system, &full);
            computeLoad();
        }
        SymmetricCsc J = system.K;
        std::vector<double> residual(system.free, 0.0);
        system.K.multiply(T, residual);
        for (int i = 0; i < system.free; ++i) residual[i] -= load[i];
        radiationTerms(system, full, residual, &J);
        SparseCholesky cholesky;
        if (!cholesky.factor(J)) return failure<ThermalSolution>(ErrorCode::KernelOperationFailed, "тепловая матрица не положительно определена");
        std::vector<double> delta;
        cholesky.solve(residual, delta);
        double change = 0.0, size = 0.0;
        for (int i = 0; i < system.free; ++i) {
            T[i] -= delta[i];
            change = std::max(change, std::fabs(delta[i]));
            size = std::max(size, std::fabs(T[i]));
        }
        solution.newtonIterations = iteration + 1;
        if ((system.radiation.empty() && !system.variable) || change <= settings.newtonTolerance * size) break;
        if (iteration + 1 == settings.maximumNewtonIterations) {
            return failure<ThermalSolution>(ErrorCode::KernelOperationFailed, "излучение или свойства от температуры: итерации не сошлись");
        }
    }
    solution.temperatureK = fullField(system, T);
    solution.minimumK = *std::min_element(solution.temperatureK.begin(), solution.temperatureK.end());
    const auto maximum = std::max_element(solution.temperatureK.begin(), solution.temperatureK.end());
    solution.maximumK = *maximum;
    solution.maximumNode = static_cast<int>(maximum - solution.temperatureK.begin());
    if (system.variable) fill(system, &solution.temperatureK);
    solution.balanceRelative = heatBalance(problem, system, solution.temperatureK);
    return Result<ThermalSolution>::ok(std::move(solution));
}

Result<TransientSolution> solveTransientThermal(const ThermalProblem& problem, const TransientSettings& settings, int saveEvery,
                                                const TransientObserver& observer) {
    if (!(settings.stepS > 0.0 && settings.endS > 0.0)) return failure<TransientSolution>(ErrorCode::InvalidArgument, "шаг и длительность должны быть положительными");
    if (!(settings.theta >= 0.5 && settings.theta <= 1.0)) return failure<TransientSolution>(ErrorCode::InvalidArgument, "θ от 1/2 до 1 (устойчивые схемы)");
    ThermalSystem system;
    if (const auto message = assemble(problem, true, system)) return failure<TransientSolution>(ErrorCode::InvalidArgument, *message);
    if (!settings.initialFieldK.empty()) {
        if (static_cast<int>(settings.initialFieldK.size()) != system.nodes) return failure<TransientSolution>(ErrorCode::InvalidArgument, "начальное поле не совпадает с сеткой");
        for (double value : settings.initialFieldK)
            if (!(value > 0.0)) return failure<TransientSolution>(ErrorCode::InvalidArgument, "начальная температура в кельвинах");
    } else if (!(settings.initialK > 0.0)) {
        return failure<TransientSolution>(ErrorCode::InvalidArgument, "начальная температура в кельвинах");
    }
    const auto& schedule = settings.schedule;
    if (schedule.irradianceWm2 && !problem.sunlight) return failure<TransientSolution>(ErrorCode::InvalidArgument, "облучённость во времени задана, а солнца в задаче нет");
    const double dt = settings.stepS, theta = settings.theta;
    const int steps = static_cast<int>(std::ceil(settings.endS / dt - 1e-9));
    std::vector<double> T(system.free, settings.initialK);
    if (!settings.initialFieldK.empty())
        for (int node = 0; node < system.nodes; ++node)
            if (system.reduced[node] >= 0) T[system.reduced[node]] = settings.initialFieldK[node];
    TransientSolution solution;
    auto save = [&](double time, std::vector<double> full) {
        solution.timeS.push_back(time);
        solution.maximumK.push_back(*std::max_element(full.begin(), full.end()));
        solution.temperatureK.push_back(std::move(full));
    };
    save(0.0, fullField(system, T));

    // Loads at time t: the constant part, convection towards the air of the moment, the sun of the moment.
    std::optional<std::string> scheduleError;
    auto loadAt = [&](double t, std::vector<double>& out) {
        const bool air = static_cast<bool>(schedule.airK);
        const double ambient = air ? schedule.airK(t) + schedule.convectionRiseK : 0.0;
        const double sun = schedule.irradianceWm2 ? schedule.irradianceWm2(t) : system.irradianceWm2;
        if (air && !(ambient > 0.0)) scheduleError = "температура воздуха по расписанию должна быть в кельвинах, > 0";
        if (!(sun >= 0.0)) scheduleError = "облучённость по расписанию не может быть отрицательной";
        const double fluxScale = schedule.fluxScale ? schedule.fluxScale(t) : 1.0;
        const double volumeScale = schedule.volumetricScale ? schedule.volumetricScale(t) : 1.0;
        out.resize(system.free);
        for (int i = 0; i < system.free; ++i) {
            out[i] = system.f[i] + fluxScale * system.fFlux[i] + volumeScale * system.fVolume[i]
                     + (air ? system.convectionPerK[i] * ambient : system.convectionFixed[i]) + sun * system.solarPerWm2[i];
        }
    };
    auto surroundingsAt = [&](double t, double& value) -> const double* {
        if (!schedule.airK) return nullptr;
        value = schedule.airK(t);
        return &value;
    };

    // One θ-step of size h from t: (C/h + θK) Tⁿ⁺¹ + θ r(Tⁿ⁺¹, tⁿ⁺¹) = (C/h) Tⁿ − (1−θ)(K Tⁿ + r(Tⁿ, tⁿ) − fⁿ) + θ fⁿ⁺¹.
    // Linear: one factorisation per (h, θ). With radiation: the chord method — the operator with the
    // radiation tangent at some recent temperature is factored once and reused while it converges
    // fast; when it slows down (the field has moved far from where the tangent was taken) it is
    // refactored at the current temperature, which makes the next iterations Newton's.
    struct Factor {
        std::unique_ptr<SymmetricCsc> matrix;
        std::unique_ptr<SparseCholesky> cholesky;
    };
    std::map<std::pair<double, double>, Factor> factors;
    const bool nonlinear = !system.radiation.empty();
    std::vector<double> CT(system.free), KT(system.free), rOld(system.free), rhs(system.free), fOld, fNew, delta, residual(system.free),
        radiative(system.free);
    auto refactor = [&](double h, double th, Factor& factor) -> bool {
        auto matrix = std::make_unique<SymmetricCsc>(system.K);
        for (std::size_t i = 0; i < matrix->values.size(); ++i) matrix->values[i] = system.C.values[i] / h + th * system.K.values[i];
        if (nonlinear) {
            SymmetricCsc tangent = system.K;
            std::fill(tangent.values.begin(), tangent.values.end(), 0.0);
            std::vector<double> unused(system.free, 0.0);
            radiationTerms(system, fullField(system, T), unused, &tangent);
            for (std::size_t i = 0; i < matrix->values.size(); ++i) matrix->values[i] += th * tangent.values[i];
        }
        auto cholesky = std::make_unique<SparseCholesky>();
        if (!cholesky->factor(*matrix)) return false;
        factor.matrix = std::move(matrix);
        factor.cholesky = std::move(cholesky);
        ++solution.factorisations;
        return true;
    };
    // Temperature-dependent properties: every iteration of the step takes them at the θ-weighted
    // temperature of the step, Tₚ = (1−θ)Tⁿ + θTⁿ⁺¹, refills and refactors the operator (radiation
    // linearised at the iterate, as Newton's), until the iterate stops moving.
    auto variableStep = [&](double t, double h, double th) -> std::optional<std::string> {
        double sOld = 0.0, sNew = 0.0;
        const double* surroundingsOld = surroundingsAt(t, sOld);
        const double* surroundingsNew = surroundingsAt(t + h, sNew);
        const std::vector<double> Told = T;
        const auto fullOld = fullField(system, Told);
        std::vector<double> properties(system.nodes), difference(system.free), KTold(system.free), radiativeOld(system.free);
        const int maximum = settings.newton.maximumNewtonIterations;
        for (int iteration = 0; iteration < maximum; ++iteration) {
            const auto fullNew = fullField(system, T);
            for (int node = 0; node < system.nodes; ++node) properties[node] = (1.0 - th) * fullOld[node] + th * fullNew[node];
            fill(system, &properties);
            loadAt(t, fOld);
            loadAt(t + h, fNew);
            if (scheduleError) return scheduleError;
            for (int i = 0; i < system.free; ++i) difference[i] = T[i] - Told[i];
            system.C.multiply(difference, CT);
            system.K.multiply(T, KT);
            system.K.multiply(Told, KTold);
            std::fill(radiative.begin(), radiative.end(), 0.0);
            std::fill(radiativeOld.begin(), radiativeOld.end(), 0.0);
            SymmetricCsc tangent = system.K;
            std::fill(tangent.values.begin(), tangent.values.end(), 0.0);
            if (nonlinear) {
                radiationTerms(system, fullNew, radiative, &tangent, surroundingsNew);
                radiationTerms(system, fullOld, radiativeOld, nullptr, surroundingsOld);
            }
            for (int i = 0; i < system.free; ++i) {
                residual[i] = CT[i] / h + th * (KT[i] + radiative[i] - fNew[i]) + (1.0 - th) * (KTold[i] + radiativeOld[i] - fOld[i]);
            }
            SymmetricCsc J = system.K;
            for (std::size_t i = 0; i < J.values.size(); ++i) J.values[i] = system.C.values[i] / h + th * (system.K.values[i] + tangent.values[i]);
            SparseCholesky cholesky;
            if (!cholesky.factor(J)) return std::string("тепловая матрица не положительно определена");
            ++solution.factorisations;
            std::vector<double> copy = residual;
            cholesky.solve(copy, delta);
            double change = 0.0, size = 0.0;
            for (int i = 0; i < system.free; ++i) {
                T[i] -= delta[i];
                change = std::max(change, std::fabs(delta[i]));
                size = std::max(size, std::fabs(T[i]));
            }
            if (change <= settings.newton.newtonTolerance * size) return std::nullopt;
        }
        return std::string("свойства от температуры: итерации шага не сошлись");
    };
    auto step = [&](double t, double h, double th) -> std::optional<std::string> {
        if (system.variable) return variableStep(t, h, th);
        double sOld = 0.0, sNew = 0.0;
        const double* surroundingsOld = surroundingsAt(t, sOld);
        const double* surroundingsNew = surroundingsAt(t + h, sNew);
        loadAt(t, fOld);
        loadAt(t + h, fNew);
        if (scheduleError) return scheduleError;
        system.C.multiply(T, CT);
        system.K.multiply(T, KT);
        std::fill(rOld.begin(), rOld.end(), 0.0);
        if (nonlinear) radiationTerms(system, fullField(system, T), rOld, nullptr, surroundingsOld);
        for (int i = 0; i < system.free; ++i) rhs[i] = CT[i] / h - (1.0 - th) * (KT[i] + rOld[i] - fOld[i]) + th * fNew[i];
        auto& factor = factors[{h, th}];
        if (!factor.cholesky && !refactor(h, th, factor)) return std::string("тепловая матрица не положительно определена");
        if (!nonlinear) {
            std::vector<double> copy = rhs, next;
            factor.cholesky->solve(copy, next);
            T = next;
            return std::nullopt;
        }
        const int maximum = settings.newton.maximumNewtonIterations;
        for (int iteration = 0; iteration < maximum; ++iteration) {
            system.C.multiply(T, CT);
            system.K.multiply(T, KT);
            std::fill(radiative.begin(), radiative.end(), 0.0);
            radiationTerms(system, fullField(system, T), radiative, nullptr, surroundingsNew);
            for (int i = 0; i < system.free; ++i) residual[i] = CT[i] / h + th * (KT[i] + radiative[i]) - rhs[i];
            // Slow convergence: take the tangent here (a Newton step from now on).
            if (iteration > 0 && iteration % 8 == 0 && !refactor(h, th, factor)) return std::string("тепловая матрица не положительно определена");
            std::vector<double> copy = residual;
            factor.cholesky->solve(copy, delta);
            double change = 0.0, size = 0.0;
            for (int i = 0; i < system.free; ++i) {
                T[i] -= delta[i];
                change = std::max(change, std::fabs(delta[i]));
                size = std::max(size, std::fabs(T[i]));
            }
            if (change <= settings.newton.newtonTolerance * size) return std::nullopt;
        }
        return std::string("излучение: итерации не сошлись");
    };
    for (int n = 1; n <= steps; ++n) {
        const double t = (n - 1) * dt;
        // Crank–Nicolson does not damp stiff components (its amplification tends to −1), so a sudden
        // change — a face switched to a new temperature — rings on for ever. The first step is taken
        // as four backward-Euler quarter steps instead (Rannacher 1984), which keeps second order.
        if (n == 1 && theta < 1.0) {
            for (int k = 0; k < 4; ++k)
                if (const auto message = step(t + k * dt / 4.0, dt / 4.0, 1.0)) return failure<TransientSolution>(ErrorCode::KernelOperationFailed, *message);
        } else if (const auto message = step(t, dt, theta)) {
            return failure<TransientSolution>(ErrorCode::KernelOperationFailed, *message);
        }
        const bool last = n == steps;
        if (observer || n % std::max(1, saveEvery) == 0 || last) {
            auto full = fullField(system, T);
            const bool go = !observer || observer(n * dt, full);
            if (!go || n % std::max(1, saveEvery) == 0 || last) save(n * dt, std::move(full));
            if (!go) break;
        }
    }
    return Result<TransientSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
