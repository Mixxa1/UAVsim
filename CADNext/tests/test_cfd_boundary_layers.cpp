#include "fea_test_support.hpp"
#include "cadnext/cfd/FlowDomain.hpp"
#include "cadnext/cfd/FluidMesher.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include <cmath>
#include <map>
#include <algorithm>

using namespace cadnext;
using fea_test::check;
namespace {
using P=std::array<double,3>;
double triple(P a,P b,P c){return a[0]*(b[1]*c[2]-b[2]*c[1])-a[1]*(b[0]*c[2]-b[2]*c[0])+a[2]*(b[0]*c[1]-b[1]*c[0]);}
P minus(P a,P b){return {a[0]-b[0],a[1]-b[1],a[2]-b[2]};}
double tet(P a,P b,P c,P d){return triple(minus(b,a),minus(c,a),minus(d,a))/6;}
}
int main(){
    kernel::OcctKernel kernel;
    auto sphere=kernel.makeSphere({0.5});
    auto domain=cfd::buildFlowDomain(kernel,{{"sphere",sphere.value()}},{3});
    check(domain.isOk(),"sphere fluid domain builds"); if(!domain.isOk())return 1;
    std::map<int,std::string> walls;for(int f:domain.value().wallFaces)walls[f]="wall";
    cfd::FluidMeshSettings settings;settings.wallElementSizeM=.13;settings.farfieldElementSizeM=1;
    settings.layerHeightsM={.005,.007,.01,.014,.02};
    const auto generated=cfd::meshFluidDomain(kernel,domain.value().domain,walls,settings);
    check(generated.isOk(),"mesh with boundary-layer prisms builds",generated.error().message);if(!generated.isOk())return 1;
    const auto& mesh=generated.value().mesh;
    check(generated.value().prisms>0 && generated.value().tetrahedra>0,"both near-wall prisms and outer tetrahedra exist");
    double volume=0;std::map<std::vector<int>,int> faces;
    auto add=[&](const cfd::Su2Element& e,std::initializer_list<int> indices){std::vector<int> face;for(int i:indices)face.push_back(e.nodes[i]);std::sort(face.begin(),face.end());++faces[face];};
    for(const auto& e:mesh.elements){
        auto p=[&](int i){return mesh.points[e.nodes[i]];};
        switch(e.type){
        case cfd::Su2ElementType::Tetrahedron:
            volume+=tet(p(0),p(1),p(2),p(3));
            add(e,{0,1,2});add(e,{0,1,3});add(e,{0,2,3});add(e,{1,2,3});break;
        case cfd::Su2ElementType::Prism:
            volume+=tet(p(0),p(1),p(2),p(3))+tet(p(1),p(2),p(3),p(4))+tet(p(2),p(3),p(4),p(5));
            add(e,{0,1,2});add(e,{3,4,5});add(e,{0,1,4,3});add(e,{1,2,5,4});add(e,{2,0,3,5});break;
        case cfd::Su2ElementType::Pyramid:
            volume+=tet(p(0),p(1),p(2),p(4))+tet(p(0),p(2),p(3),p(4));
            add(e,{0,1,2,3});add(e,{0,1,4});add(e,{1,2,4});add(e,{2,3,4});add(e,{3,0,4});break;
        default:check(false,"unsupported cell in fluid mesh");
        }
    }
    double enclosed=0; bool externalFacesValid=true;
    for(const auto& [name,boundary]:mesh.markers){
        double signedVolume=0;
        for(const auto& f:boundary){
            const auto& n=f.nodes; signedVolume+=triple(mesh.points[n[0]],mesh.points[n[1]],mesh.points[n[2]])/6;
            if(n.size()==4)signedVolume+=triple(mesh.points[n[0]],mesh.points[n[2]],mesh.points[n[3]])/6;
            auto key=n;std::sort(key.begin(),key.end());
            externalFacesValid = externalFacesValid && faces[key]==1; faces.erase(key);
        }
        enclosed+=(name=="farfield"?1:-1)*std::abs(signedVolume);
    }
    check(externalFacesValid,"each external face belongs to exactly one fluid cell");
    check(std::all_of(faces.begin(),faces.end(),[](const auto& f){return f.second==2;}),"every internal interface joins exactly two cells (no overlapping layer)");
    std::printf("  volume: cells %.12g, boundary %.12g\n",volume,enclosed);
    // Warped prism quadrilaterals can use different diagonals in adjacent cell
    // decompositions. Allow that small triangulation discrepancy (1 ppm), while
    // the incidence checks above independently reject disconnected/overlapping layers.
    check(std::abs(volume-enclosed)<1e-6*enclosed,"sum of cell volumes equals volume enclosed by the surface mesh (1 ppm)");
    // Every requested layer lies outside the solid sphere, inside the fluid.
    double minimum=1e9;
    for(const auto& e:mesh.elements)if(e.type==cfd::Su2ElementType::Prism)for(int n:e.nodes){const auto& p=mesh.points[n];minimum=std::min(minimum,std::sqrt(p[0]*p[0]+p[1]*p[1]+p[2]*p[2]));}
    check(minimum>=.5-1e-9,"layers grow into the fluid, not into the aircraft");
    return fea_test::finish("test_cfd_boundary_layers");
}
