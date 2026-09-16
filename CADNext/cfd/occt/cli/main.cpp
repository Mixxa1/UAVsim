#include "cadnext/cfd/AerodynamicStudy.hpp"
#include "cadnext/cfd/FlowDomain.hpp"
#include "cadnext/cfd/FluidMesher.hpp"
#include "cadnext/bridge/ConstructionBuilder.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepPrimAPI_MakeBox.hxx>
#include <gp_Pnt.hxx>
#include <csignal>
#include <unistd.h>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <regex>
#include <map>

using namespace cadnext;
namespace fs = std::filesystem;
namespace {
volatile std::sig_atomic_t cancelled = 0;
volatile std::sig_atomic_t solverActive = 0;
void cancel(int) {
    cancelled = 1;
    // Netgen is not cooperatively cancellable. While no child solver exists, ending this
    // isolated worker is safe. During SU2, allow runSu2 to terminate/reap its process group.
    if (!solverActive) _exit(130);
}
std::string read(const fs::path& p) { std::ifstream f(p,std::ios::binary); if (!f) throw std::runtime_error("не удалось прочитать "+p.string()); return {std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()}; }
void write(const fs::path& p,const std::string& text) {
    fs::create_directories(p.parent_path());
    const auto temp=p.string()+".partial";
    { std::ofstream f(temp,std::ios::binary|std::ios::trunc); if (!f || !(f<<text)) throw std::runtime_error("не удалось записать "+p.string()); }
    fs::rename(temp,p);
}
void progress(int point,const char* stage,int iteration=0) { std::printf("progress %d %s %d\n",point,stage,iteration); std::fflush(stdout); }
std::string embedded(cfd::Json j) {
    std::string out; for (char c:j.serialize()) { if (c=='<') out+="\\u003c"; else if (c=='>') out+="\\u003e"; else if (c=='&') out+="\\u0026"; else out+=c; } return out;
}
#include "AeroReportTemplate.inc"
}
int main(int argc,char** argv) {
    if (argc==2 && std::string(argv[1])=="--capabilities") { std::puts(cfd::aeroCapabilitiesJson().c_str()); return 0; }
    if (argc!=2) { std::fprintf(stderr,"usage: cadnext_cfd <job.json> | --capabilities\n"); return 64; }
    std::signal(SIGTERM,cancel); std::signal(SIGINT,cancel);
    std::optional<cfd::AeroJob> job;
    std::vector<cfd::AeroSample> samples;
    std::string solverVersion="unknown",mesherVersion="unknown";
    bool ownsOutput = false;
    cfd::Json fields=cfd::Json::makeArray();
    auto finish=[&](const std::string& error) {
        if (!job || !ownsOutput) return;
        auto result=cfd::aeroResultJson(*job,samples,solverVersion,mesherVersion,error);
        write(job->resultPath,result.serialize());
        auto reportData=result; reportData.set("surfaces",fields);
        std::string report=kAeroReportTemplate;
        const auto pos=report.find("__CFD_DATA__"); report.replace(pos,12,embedded(reportData));
        write(fs::path(job->resultPath).parent_path()/"report.html",report);
    };
    try {
        const auto path=fs::absolute(argv[1]);
        const auto parsed=cfd::parseAeroJob(read(path),path.parent_path().string());
        if (!parsed.isOk()) throw std::runtime_error(parsed.error().message);
        job=parsed.value();
        // Refuse to reuse a run directory, even if a previous process crashed before its result.
        if (fs::exists(job->workDirectory)) throw std::runtime_error("каталог CFD уже существует; создайте новый запуск");
        if (fs::exists(job->resultPath)) throw std::runtime_error("файл результата уже существует; создайте новый запуск");
        fs::create_directories(job->workDirectory);
        ownsOutput = true;
        kernel::OcctKernel kernel;
        std::vector<cfd::FlowBody> bodies;
        for (const auto& g:job->geometry) {
            const std::string brep=read(g.path);
            if (bridge::sha256Hex(brep)!=g.sha256) throw std::runtime_error("SHA-256 геометрии не совпадает: "+g.id);
            auto shape=kernel.importBRep({brep.begin(),brep.end()});
            if (!shape.isOk()) throw std::runtime_error(shape.error().message);
            auto volume=kernel.volumeProperties(shape.value());
            if (!volume.isOk() || !(volume.value().volumeM3>0)) throw std::runtime_error("тело не является замкнутым solid: "+g.id);
            bodies.push_back({g.id,shape.value()});
        }
        for (const auto& p:job->proxies) {
            const bridge::ConstructionAxes axes{job->cadForward,job->cadUp};
            const auto center=bridge::modelToCad(axes,{p.centerModelM[0],p.centerModelM[1],p.centerModelM[2]}).value();
            const auto size=bridge::modelToCad(axes,{p.sizeModelM[0],p.sizeModelM[1],p.sizeModelM[2]}).value();
            const double x=std::abs(size.x),y=std::abs(size.y),z=std::abs(size.z);
            auto shape=BRepPrimAPI_MakeBox(gp_Pnt(center.x-x/2,center.y-y/2,center.z-z/2),x,y,z).Shape();
            bodies.push_back({p.id,kernel.adoptShape(shape,"equipment-envelope")});
        }
        if (cancelled) throw std::runtime_error("расчёт отменён");
        progress(0,"domain");
        const auto domain=cfd::buildFlowDomain(kernel,bodies,{job->settings.farfieldLengths});
        if (!domain.isOk()) throw std::runtime_error(domain.error().message);
        std::map<std::string,std::string> bodyMarkers;
        for (std::size_t i=0;i<bodies.size();++i) bodyMarkers[bodies[i].id]="body_"+std::to_string(i);
        std::map<int,std::string> wallMarkers;
        for (const auto& wall:domain.value().walls) wallMarkers[wall.domainFace]=bodyMarkers.at(wall.bodyId);
        // Preserve CAD face provenance separately from safe SU2 marker identifiers.
        auto mapping=cfd::Json::makeArray();
        for (const auto& wall:domain.value().walls) {
            auto row=cfd::Json::makeObject(); row.set("bodyId",cfd::Json::makeString(wall.bodyId));
            row.set("bodyFace",cfd::Json::makeString(wall.bodyFace)); row.set("marker",cfd::Json::makeString(bodyMarkers.at(wall.bodyId)));
            mapping.arrayItems.push_back(row);
        }
        write(fs::path(job->workDirectory)/"wall-origins.json",mapping.serialize());
        progress(0,"mesh");
        const auto& s=job->settings;
        const auto meshed=cfd::meshFluidDomain(kernel,domain.value().domain,wallMarkers,{s.farfieldSizeM,s.wallSizeM,s.grading,s.layerHeightsM});
        if (!meshed.isOk()) throw std::runtime_error(meshed.error().message);
        if (cancelled) throw std::runtime_error("расчёт отменён");
        mesherVersion=meshed.value().mesherVersion;
        auto mesh=meshed.value().mesh;
        for (auto& p:mesh.points) p=cfd::cadToSolver(job->cadForward,job->cadUp,p).value();
        const auto meshPath=fs::path(job->workDirectory)/"mesh.su2";
        if (!mesh.write(meshPath.string())) throw std::runtime_error("не удалось записать сетку");
        std::vector<std::string> names; for (const auto& marker:mesh.markers) if (marker.first!="farfield") names.push_back(marker.first);
        int index=0;
        for (double alpha:s.alphaDeg) for (double beta:s.betaDeg) {
            if (cancelled) throw std::runtime_error("расчёт отменён");
            const auto directory=fs::path(job->workDirectory)/("point-"+std::to_string(index));
            fs::create_directory(directory);
            fs::create_hard_link(meshPath,directory/"mesh.su2");
            progress(index,"solve");
            cfd::Su2RunControl control;
            control.cancel=[] { return cancelled!=0; }; control.timeoutSeconds=s.timeoutSeconds;
            control.progress=[&](const cfd::Su2History& h) { progress(index,"solve",static_cast<int>(h.rows.size())); };
            solverActive = 1;
            const auto run=cfd::runSu2(job->solverPath,directory.string(),cfd::aeroConfig(s,alpha,beta,names),s.threads,control);
            solverActive = 0;
            if (!run.isOk()) throw std::runtime_error(run.error().message);
            {
                std::ifstream log(directory/"su2.log"); std::string header(8192,'\0'); log.read(header.data(),header.size()); header.resize(log.gcount());
                std::smatch match;
                if (std::regex_search(header,match,std::regex("Release ([0-9]+\\.[0-9]+\\.[0-9]+)"))) solverVersion="SU2 "+match[1].str()+" / cadnext-cfd 1";
            }
            auto point=cfd::collectAeroSample(run.value(),s,alpha,beta);
            if (!point.isOk()) throw std::runtime_error("точка "+std::to_string(index)+": "+point.error().message);
            if (solverVersion=="unknown") throw std::runtime_error("не удалось определить версию SU2 из журнала");
            auto sample=point.value();
            sample.directory=fs::relative(directory,fs::path(job->resultPath).parent_path()).generic_string();
            // Field files are part of a successful point. Do not claim a complete run if writing
            // them failed (e.g. the disk filled after the history was flushed).
            const auto surface=cfd::parseSu2History(read(directory/"surface.csv"));
            if (!surface.isOk() || surface.value().empty() || !fs::exists(directory/"volume.vtu")) throw std::runtime_error("SU2 не записал полные поля давления/скорости");
            const auto& h=surface.value();
            auto field=cfd::Json::makeObject(); auto rows=cfd::Json::makeArray();
            std::vector<int> columns;
            for (const auto* key:{"x","y","z","Pressure_Coefficient","Velocity_x","Velocity_y","Velocity_z"}) columns.push_back(h.column(key));
            if (std::any_of(columns.begin(),columns.end(),[](int c){return c<0;})) throw std::runtime_error("неизвестный формат поля SU2");
            for (const auto& row:h.rows) {
                auto values=cfd::Json::makeArray();
                for (std::size_t i=0;i<columns.size();++i)
                    values.arrayItems.push_back(cfd::Json::makeNumber(row[columns[i]]*(i>=4 ? s.speedMps : 1.0)));
                rows.arrayItems.push_back(values);
            }
            field.set("rows",rows); fields.arrayItems.push_back(field);
            samples.push_back(sample); progress(index,"collected"); ++index;
        }
        finish("");
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr,"cadnext_cfd: %s\n",error.what());
        try { finish(error.what()); } catch (const std::exception& writeError) { std::fprintf(stderr,"%s\n",writeError.what()); }
        return 2;
    }
}
