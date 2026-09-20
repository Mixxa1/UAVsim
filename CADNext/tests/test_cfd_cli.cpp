#include "fea_test_support.hpp"
#include "cadnext/cfd/AerodynamicStudy.hpp"
#include "cadnext/cfd/FlowSection.hpp"
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
        if (s.model=="urans_sst") {
            s.alphaDeg={0};s.betaDeg={0};s.timeSteps=36;s.innerIterations=15;s.averagingSteps=12;s.timeStepSeconds=.005;
            s.residualTarget=-3;s.coefficientAbsoluteTolerance=.15;s.coefficientRelativeTolerance=.15;
        }
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
    check(fs::exists(run/"flow/point-0/surface.csv") && fs::exists(run/"flow/point-0/volume.vtu"),"pressure and velocity artifacts exist");
    check(!fs::exists(run/"report.html"), "CFD output uses native result windows and does not create HTML");
    if(s.model=="urans_sst") {
        std::size_t frames=0;const fs::path frameDirectory=run/"flow/point-0";
        std::size_t fullFrames=0;
        if(fs::exists(frameDirectory))for(const auto& file:fs::directory_iterator(frameDirectory)){const auto name=file.path().filename().string();if(name.starts_with("section_")&&name.ends_with(".csv"))++frames;if(name.starts_with("volume_"))++fullFrames;}
        check(frames>=2,"URANS preserves multiple physical-time frames of the section for native playback");
        check(fullFrames==0&&fs::exists(frameDirectory/"volume.csv"),"full volume frames are reduced to the section; the last full field is kept");
        check(fs::exists(run/"flow/section.json"),"the section plane is recorded for the window");
    }
    std::ifstream volumeFile(run/"flow/point-0/volume.csv");
    std::string volume{std::istreambuf_iterator<char>(volumeFile),std::istreambuf_iterator<char>()};
    const auto field=cfd::parseSu2History(volume);
    check(field.isOk() && !field.value().empty() && field.value().column("Velocity_x")>=0 && field.value().column("x")>=0,
          "native airflow viewer receives actual volumetric coordinates and velocity");
    if(field.isOk()) {
        const auto& h=field.value();
        std::vector<cfd::FlowSection::Vector> velocities(h.rows.size(),{NAN,NAN,NAN});
        for(const auto& row:h.rows){const auto id=std::size_t(row[h.column("PointID")]);if(id<velocities.size())velocities[id]={row[h.column("Velocity_x")],row[h.column("Velocity_y")],row[h.column("Velocity_z")]};}
        std::ifstream mesh(run/"flow/point-0/mesh.su2");
        try {
            const auto section=cfd::FlowSection::read(mesh,velocities,0,{-2,3,-2,2});
            check(!section.walls.empty(),"viewer uses body boundary from this result's mesh");
            cfd::FlowSection::Vector v{};
            check(!section.sample(0,0,v),"actual SU2 sphere section contains no fluid inside the body");
            check(section.sample(-1,0,v) && std::isfinite(v[0]),"actual SU2 fluid cells provide the upstream section field");
        } catch(const std::exception& e){check(false,"actual SU2 section loads",e.what());}
    }
    return fea_test::finish("test_cfd_cli");
}
