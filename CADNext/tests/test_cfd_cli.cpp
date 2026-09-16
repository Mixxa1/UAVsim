#include "fea_test_support.hpp"
#include "cadnext/cfd/AerodynamicStudy.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/bridge/ConstructionBuilder.hpp"
#include <filesystem>
#include <fstream>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
using namespace cadnext;
using fea_test::check;
namespace fs=std::filesystem;
int main(int argc,char** argv) {
    if(argc!=4 && argc!=5) return 64;
    const fs::path directory=fs::absolute(argv[3]); fs::create_directories(directory);
    const auto run=directory/("run-"+std::to_string(getpid())); fs::create_directory(run);
    kernel::OcctKernel kernel;
    const auto sphere=kernel.makeSphere({0.5});
    bridge::ConstructionBuildRequest frame;
    frame.id="cfd-sphere"; frame.name="CFD integration sphere"; frame.cadAxes={"+x","+z"};
    frame.bodies={{"sphere","Sphere",sphere.value(),"test-material",1}};
    const auto construction=bridge::buildConstruction(kernel,frame);
    check(construction.isOk() && bridge::ConstructionExport::saveToFile(construction.value(),(run/"sphere.uavframe").string()).isOk(),
          "the exact test solid also exports as a Workbench frame");
    const auto brep=kernel.exportBRepGeometry(sphere.value());
    const std::string text(brep.value().begin(),brep.value().end());
    {std::ofstream f(run/"sphere.brep"); f<<text;}
    cfd::AeroSettings s; s.model="euler"; s.alphaDeg={0}; s.betaDeg={0}; s.speedMps=10;
    s.reference={0.7853981633974483,1,1,{0,0,0}}; s.wallSizeM=.12; s.farfieldSizeM=1.5; s.farfieldLengths=5;
    s.iterations=600; s.convergenceWindow=20; s.residualTarget=-5; s.coefficientAbsoluteTolerance=1e-3; s.threads=2;
    if (argc==5) {
        s.model=argv[4]; s.viscosityPaS=.6125; s.layerHeightsM={.005,.007,.01,.014,.02};
        s.iterations=1500; s.alphaDeg={-5,0,5}; s.betaDeg={0};
        if (s.model=="sst") { s.alphaDeg={0}; s.betaDeg={-5,0,5}; }
    }
    auto root=cfd::Json::makeObject(); auto str=[](const std::string& v){return cfd::Json::makeString(v);};
    root.set("schema",str("cadnext-aerodynamics-job/1"));root.set("solverPath",str(fs::absolute(argv[2]).string()));root.set("settings",cfd::aeroSettingsJson(s));
    auto axes=cfd::Json::makeObject();axes.set("forward",str("+x"));axes.set("up",str("+z"));axes.set("lengthUnit",str("m"));root.set("cadAxes",axes);
    auto bodies=cfd::Json::makeArray();auto body=cfd::Json::makeObject();body.set("id",str("sphere"));body.set("path",str("sphere.brep"));body.set("sha256",str(bridge::sha256Hex(text)));bodies.arrayItems.push_back(body);root.set("geometry",bodies);
    const auto path=run/"job.json";{std::ofstream f(path);f<<root.serialize();}
    std::string cli=fs::absolute(argv[1]).string(), job=path.string();char* args[]={cli.data(),job.data(),nullptr};pid_t pid;
    const int launched=posix_spawn(&pid,cli.c_str(),nullptr,nullptr,args,environ);int status=-1;if(!launched)waitpid(pid,&status,0);
    check(launched==0 && WIFEXITED(status) && WEXITSTATUS(status)==0,"real CAD → domain → mesh → SU2 → complete result",run.string());
    std::ifstream f(run/"result.json");std::string json{std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()};cfd::Json result;std::string error;
    const bool parsed=fea::json::parseJson(json,result,error);
    check(parsed && result.stringOr("outcome","")=="warning","completed point is WARNING with spatial uncertainty unknown");
    if (parsed && result.stringOr("outcome","")!="error") {
        const auto* table=result.member("aeroTable"); const auto* points=table ? table->member("points") : nullptr;
        check(points && points->arrayItems.size()==s.alphaDeg.size()*s.betaDeg.size(),"every requested angle is present in the exported map");
        if(points && s.model!="euler") {
            for(const auto& point:points->arrayItems) {
                check(point.numberOr("cd",0)>1 && point.numberOr("cd",0)<5,"viscous drag at Re=20 has a plausible sphere magnitude (not a grid-convergence claim)");
                check(std::abs(point.numberOr("cy",1))<.2 && std::abs(point.numberOr("cl",1))<.2,"sphere has small transverse forces across the angle sweep");
            }
        }
    } else if(parsed) std::printf("result: %s\n",json.c_str());
    check(fs::exists(run/"report.html") && fs::exists(run/"flow/point-0/surface.csv") && fs::exists(run/"flow/point-0/volume.vtu"),"report and pressure/velocity artifacts exist");
    return fea_test::finish("test_cfd_cli");
}
