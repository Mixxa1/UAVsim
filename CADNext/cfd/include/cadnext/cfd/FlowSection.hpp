#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <istream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace cadnext::cfd {

// A planar section of the actual fluid cells, in solver coordinates (x, z).
// No extrapolation across walls or into gaps in the mesh is permitted.
//
// The cut is computed once from the mesh; the velocity on it can then be replaced (`refresh`) from
// the velocities of just the mesh nodes the cut uses (`referencedNodes`), without reading the mesh
// again. That is what lets a time-accurate run play frame after frame, and blend between frames,
// at display rate.
class FlowSection {
public:
    using Vector = std::array<double, 3>;
    // Each vertex lies on a mesh edge a–b at parameter t; a and b index referencedNodes().
    struct Vertex { double x, z; Vector velocity; std::size_t a = 0, b = 0; double t = 0; };
    using Triangle = std::array<Vertex, 3>;
    std::vector<Triangle> triangles;
    std::vector<std::array<Vector,3>> walls;
    std::size_t meshNodes = 0, meshCells = 0;

    static FlowSection read(std::istream& input, const std::vector<Vector>& velocity,
                            double planeY, std::array<double, 4> bounds) {
        FlowSection section;
        for(double b:bounds)if(!std::isfinite(b))throw std::runtime_error("Invalid section bounds");
        if(!std::isfinite(planeY)||bounds[1]<=bounds[0]||bounds[3]<=bounds[2])throw std::runtime_error("Invalid section bounds");
        section.bounds_ = bounds;
        std::string line;
        struct Cell { std::vector<int> nodes; int type; };
        std::vector<Cell> cells;
        std::vector<Vector> points;
        bool dimensionOK = false;
        while (std::getline(input, line)) {
            auto equal = line.find('=');
            if (equal == std::string::npos) continue;
            std::istringstream value(line.substr(equal + 1));
            std::size_t count = 0;
            if (!(value >> count)) continue;
            if (line.find("NDIME") == 0) dimensionOK = count == 3;
            if (line.find("NELEM") == 0) {
                for (std::size_t i = 0; i < count; ++i) {
                    if (!std::getline(input, line)) throw std::runtime_error("Incomplete mesh cells");
                    std::istringstream row(line); Cell cell;
                    if(!(row >> cell.type))throw std::runtime_error("Invalid cell type");
                    int n = cell.type == 10 ? 4 : cell.type == 13 ? 6 : cell.type == 14 ? 5 : 0;
                    if (!n) throw std::runtime_error("Unsupported fluid cell type");
                    cell.nodes.resize(n);
                    for (auto& node : cell.nodes) if (!(row >> node) || node < 0) throw std::runtime_error("Invalid cell node");
                    cells.push_back(std::move(cell));
                }
            }
            if (line.find("NPOIN") == 0) {
                points.resize(count);
                std::vector<bool> seen(count);
                for (std::size_t i = 0; i < count; ++i) {
                    if (!std::getline(input, line)) throw std::runtime_error("Incomplete mesh points");
                    std::istringstream row(line); Vector p; std::size_t id;
                    if (!(row >> p[0] >> p[1] >> p[2] >> id) || id >= count || seen[id]) throw std::runtime_error("Invalid mesh point");
                    for(double c:p)if(!std::isfinite(c))throw std::runtime_error("Invalid mesh coordinate");
                    seen[id] = true; points[id] = p;
                }
            }
            if (line.find("NMARK") == 0) {
                for(std::size_t marker=0;marker<count;++marker){
                    if(!std::getline(input,line))throw std::runtime_error("Incomplete mesh markers");
                    const bool farfield=line.find("farfield")!=std::string::npos;
                    if(!std::getline(input,line))throw std::runtime_error("Incomplete mesh marker count");
                    const auto separator=line.find('=');std::size_t faces=0;
                    if(separator==std::string::npos || !(std::istringstream(line.substr(separator+1))>>faces))throw std::runtime_error("Invalid mesh marker count");
                    for(std::size_t face=0;face<faces;++face){
                        if(!std::getline(input,line))throw std::runtime_error("Incomplete mesh boundary");
                        std::istringstream row(line);int type=0;row>>type;
                        const int nodes=type==5?3:type==9?4:0;
                        if(!nodes)throw std::runtime_error("Unsupported boundary face");
                        std::array<std::size_t,4> ids{};
                        for(int n=0;n<nodes;++n)if(!(row>>ids[n])||ids[n]>=points.size())throw std::runtime_error("Invalid boundary node");
                        if(!farfield){section.walls.push_back({points[ids[0]],points[ids[1]],points[ids[2]]});if(nodes==4)section.walls.push_back({points[ids[0]],points[ids[2]],points[ids[3]]});}
                    }
                }
                break;
            }
        }
        if (!dimensionOK || points.empty() || cells.empty() || velocity.size() != points.size()) throw std::runtime_error("Incomplete volume field");
        section.meshNodes = points.size(); section.meshCells = cells.size();
        const std::vector<std::array<int,2>> tet{{0,1},{0,2},{0,3},{1,2},{1,3},{2,3}};
        const std::vector<std::array<int,2>> prism{{0,1},{1,2},{2,0},{3,4},{4,5},{5,3},{0,3},{1,4},{2,5}};
        const std::vector<std::array<int,2>> pyramid{{0,1},{1,2},{2,3},{3,0},{0,4},{1,4},{2,4},{3,4}};
        // Tolerance from the mesh itself, not from the requested bounds: the same mesh and plane must
        // give the same cut whatever region is asked for — the solver reduces its time frames to the
        // nodes of this cut, and the window has to arrive at exactly the same nodes.
        double extent = 0.0;
        {
            Vector low{INFINITY, INFINITY, INFINITY}, high{-INFINITY, -INFINITY, -INFINITY};
            for (const auto& p : points) for (int k = 0; k < 3; ++k) { low[k] = std::min(low[k], p[k]); high[k] = std::max(high[k], p[k]); }
            for (int k = 0; k < 3; ++k) extent = std::max(extent, high[k] - low[k]);
        }
        const double epsilon = extent*1e-10;
        for (const auto& cell : cells) {
            for (int id : cell.nodes) if (std::size_t(id) >= points.size()) throw std::runtime_error("Cell node out of range");
            const auto& edges = cell.type == 10 ? tet : cell.type == 13 ? prism : pyramid;
            std::vector<Vertex> polygon;
            auto add = [&](int a, int b, double t) {
                Vertex v; v.x=points[a][0]+t*(points[b][0]-points[a][0]); v.z=points[a][2]+t*(points[b][2]-points[a][2]);
                v.a=std::size_t(a); v.b=std::size_t(b); v.t=t; // mesh ids for now, compacted below
                for(const auto& old:polygon) if(std::hypot(v.x-old.x,v.z-old.z)<epsilon) return;
                polygon.push_back(v);
            };
            for (auto edge : edges) {
                const int a=cell.nodes[edge[0]], b=cell.nodes[edge[1]];
                const double da=points[a][1]-planeY, db=points[b][1]-planeY;
                if(std::abs(da)<epsilon) add(a,a,0);
                if(std::abs(db)<epsilon) add(b,b,0);
                if((da<0 && db>0)||(da>0 && db<0)) add(a,b,da/(da-db));
            }
            if(polygon.size()<3) continue;
            double cx=0,cz=0;for(auto v:polygon){cx+=v.x;cz+=v.z;}cx/=polygon.size();cz/=polygon.size();
            std::sort(polygon.begin(),polygon.end(),[&](const Vertex& a,const Vertex& b){return std::atan2(a.z-cz,a.x-cx)<std::atan2(b.z-cz,b.x-cx);});
            for(std::size_t i=1;i+1<polygon.size();++i) {
                Triangle t{polygon[0],polygon[i],polygon[i+1]};
                if(std::abs(area(t[0],t[1],t[2]))<=epsilon*epsilon) continue;
                section.triangles.push_back(t);
            }
        }
        // Only the nodes the cut actually uses need a velocity; a volume field may leave the rest
        // out (a time frame written for this section alone does).
        std::vector<std::size_t> compact(points.size(), std::size_t(-1));
        for (auto& t : section.triangles) for (auto& v : t) for (auto* id : {&v.a, &v.b}) {
            if (compact[*id] == std::size_t(-1)) { compact[*id] = section.nodes_.size(); section.nodes_.push_back(*id); }
            *id = compact[*id];
        }
        std::vector<Vector> used(section.nodes_.size());
        for (std::size_t i = 0; i < used.size(); ++i) used[i] = velocity[section.nodes_[i]];
        section.refresh(used);
        section.index();
        return section;
    }

    // Mesh node ids whose velocity the cut interpolates, in the order refresh() expects.
    const std::vector<std::size_t>& referencedNodes() const { return nodes_; }

    // Replaces the velocity on the cut; `nodeVelocity[i]` belongs to referencedNodes()[i].
    void refresh(const std::vector<Vector>& nodeVelocity) {
        if (nodeVelocity.size() != nodes_.size()) throw std::runtime_error("Section velocity does not match its nodes");
        for (const auto& v : nodeVelocity) for (double c : v) if (!std::isfinite(c)) throw std::runtime_error("Incomplete volume field");
        for (auto& t : triangles) for (auto& v : t)
            for (int k = 0; k < 3; ++k) v.velocity[k] = nodeVelocity[v.a][k] + v.t * (nodeVelocity[v.b][k] - nodeVelocity[v.a][k]);
    }

    bool sample(double x, double z, Vector& velocity) const {
        if(x<bounds_[0]||x>bounds_[1]||z<bounds_[2]||z>bounds_[3]) return false;
        Vertex p{x,z,{}};
        for(auto id:bins_[binZ(z)*resolution+binX(x)]) {
            const auto& t=triangles[id]; const double denominator=area(t[0],t[1],t[2]);
            const double a=area(p,t[1],t[2])/denominator,b=area(t[0],p,t[2])/denominator,c=1-a-b;
            if(a < -1e-9 || b < -1e-9 || c < -1e-9) continue;
            for(int k=0;k<3;++k) velocity[k]=a*t[0].velocity[k]+b*t[1].velocity[k]+c*t[2].velocity[k];
            return true;
        }
        return false;
    }
private:
    static constexpr int resolution=64;
    std::array<double,4> bounds_{};
    std::vector<std::size_t> nodes_;
    std::array<std::vector<std::size_t>,resolution*resolution> bins_;
    static double area(const Vertex& a,const Vertex& b,const Vertex& c){return (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x);}
    int binX(double x)const{return std::clamp(int((x-bounds_[0])/(bounds_[1]-bounds_[0])*resolution),0,resolution-1);}
    int binZ(double z)const{return std::clamp(int((z-bounds_[2])/(bounds_[3]-bounds_[2])*resolution),0,resolution-1);}
    void index(){
        for(std::size_t i=0;i<triangles.size();++i){const auto& t=triangles[i];
            double x0=std::min({t[0].x,t[1].x,t[2].x}),x1=std::max({t[0].x,t[1].x,t[2].x});
            double z0=std::min({t[0].z,t[1].z,t[2].z}),z1=std::max({t[0].z,t[1].z,t[2].z});
            if(x1<bounds_[0]||x0>bounds_[1]||z1<bounds_[2]||z0>bounds_[3])continue;
            for(int z=binZ(z0);z<=binZ(z1);++z)for(int x=binX(x0);x<=binX(x1);++x)bins_[z*resolution+x].push_back(i);
        }
    }
};
}
