#include "fea_test_support.hpp"
#include "cadnext/cfd/AerodynamicStudy.hpp"
#include "cadnext/cfd/FlowSection.hpp"
#include <cmath>
#include <filesystem>
#include <fstream>
#include <unistd.h>

using namespace cadnext;
using namespace cadnext::cfd;
using fea_test::check;

AeroSettings settings() {
    AeroSettings s; s.model="euler"; s.reference={2,4,0.5,{0,0,0}};
    s.wallSizeM=0.1; s.farfieldSizeM=1; s.convergenceWindow=5; s.iterations=100;
    return s;
}
Su2RunResult converged() {
    Su2RunResult r; r.exitStatus=0;
    r.history.columns={"rms[P]","rms[U]","rms[V]","rms[W]","CFx","CFy","CFz","CMx","CMy","CMz"};
    for (int i=0;i<10;++i) r.history.rows.push_back({-8,-8,-8,-8,0.2,0.3,0.8,0.4,0.5,0.6});
    return r;
}
int main() {
    // A linear vector field must be reproduced by cell-section interpolation;
    // empty space must remain empty and reversed flow must keep its sign.
    {
        std::istringstream mesh("NDIME= 3\nNELEM= 1\n10 0 1 2 3 0\nNPOIN= 4\n0 -1 0 0\n2 -1 0 1\n0 -1 2 2\n0 1 0 3\nNMARK= 0\n");
        auto section=FlowSection::read(mesh,{{-1,-1,0},{1,-1,0},{-1,-1,2},{-1,1,0}},0,{-1,3,-1,3});
        FlowSection::Vector v{};
        check(section.sample(.2,.3,v) && std::abs(v[0]+.8)<1e-12 && std::abs(v[1])<1e-12 && std::abs(v[2]-.3)<1e-12,"section reproduces linear field and reversed velocity");
        check(!section.sample(.8,.8,v),"section does not extrapolate through solid or outside fluid cells");
        check(section.meshNodes==4 && section.meshCells==1,"section reports entire mesh size");
    }
    for(int type:{13,14}) {
        const std::string vertices=type==13 ? "0 -1 0 0\n2 -1 0 1\n0 -1 2 2\n0 1 0 3\n2 1 0 4\n0 1 2 5\n" : "-1 -1 0 0\n1 -1 0 1\n1 1 0 2\n-1 1 0 3\n0 0 2 4\n";
        std::istringstream mesh("NDIME= 3\nNELEM= 1\n"+std::string(type==13?"13 0 1 2 3 4 5 0":"14 0 1 2 3 4 0")+"\nNPOIN= "+(type==13?"6":"5")+"\n"+vertices+"NMARK= 0\n");
        auto section=FlowSection::read(mesh,std::vector<FlowSection::Vector>(type==13?6:5,{-2,3,4}),0,{-2,3,-1,3});FlowSection::Vector v{};
        check(section.sample(.1,.3,v) && std::abs(v[0]+2)<1e-12 && std::abs(v[2]-4)<1e-12,"prism and pyramid sections preserve constant velocity");
    }
    {
        std::istringstream mesh("NDIME= 3\nNELEM= 1\n10 0 1 2 3 0\nNPOIN= 4\n0 -1 0 0\n2 -1 0 1\n0 -1 2 2\n0 1 0 3\nNMARK= 0\n");
        bool refused=false;try{FlowSection::read(mesh,{{1,0,0}},0,{-1,3,-1,3});}catch(const std::exception&){refused=true;}
        check(refused,"partially written volume field is refused");
    }
    check(defaultTimeoutSeconds("urans_sst")==28800 && defaultTimeoutSeconds("sst")==3600 && defaultTimeoutSeconds("laminar")==3600 && defaultTimeoutSeconds("euler")==3600,
          "a URANS point starts with eight hours, a steady one with one");
    check(timeoutAfterModelChange(3600,"sst","urans_sst")==28800 && timeoutAfterModelChange(28800,"urans_sst","sst")==3600,
          "the time limit follows the model between the two defaults");
    check(timeoutAfterModelChange(7200,"sst","urans_sst")==7200 && timeoutAfterModelChange(7200,"urans_sst","laminar")==7200,
          "a time limit the analyst set survives a model change");
    check(timeoutAfterModelChange(3600,"sst","laminar")==3600, "steady models share one limit");
    auto s=settings(); check(validateAeroSettings(s).empty(),"complete settings accepted");
    auto bad=s; bad.speedMps=INFINITY; check(!validateAeroSettings(bad).empty(),"infinite flow speed refused");
    bad=s; bad.alphaDeg={0,0}; check(!validateAeroSettings(bad).empty(),"duplicate sweep angle refused");
    bad=s; bad.model="sst"; check(!validateAeroSettings(bad).empty(),"viscous study requires wall layers");
    bad=s; bad.convergenceWindow=101; check(!validateAeroSettings(bad).empty(),"iteration count must cover the convergence window");
    auto rotated=cadToSolver("+x","+z",{1,2,3});
    check(rotated.isOk() && rotated.value()==Point3{-1,-2,3},"CAD forward/up map to aft/right/up without reflection");
    check(!cadToSolver("+x","-x",{}).isOk(),"collinear CAD axes refused");
    auto result=collectAeroSample(converged(),s,0,0);
    check(aeroConfig(s,0,0,{"wall"}).text().find("OUTPUT_WRT_FREQ= ( 25, 25, 25 )")!=std::string::npos,
          "steady CFD writes intermediate fields for the live viewer");
    check(result.isOk(),"converged force and residual history accepted");
    if (result.isOk()) {
        const auto& p=result.value();
        check(std::abs(p.cl-.8)<1e-12 && std::abs(p.cd-.2)<1e-12 && std::abs(p.cy-.3)<1e-12,"force axes at zero alpha/beta");
        check(std::abs(p.cm-.5)<1e-12 && std::abs(p.cRoll-.05)<1e-12 && std::abs(p.cYaw-.075)<1e-12,"moment signs and chord/span normalization");
    }
    const double a=20.0*std::acos(-1.0)/180, b=-15.0*std::acos(-1.0)/180;
    const auto d=flowDirection(20,-15);
    auto tilted=converged();
    for(auto& row:tilted.history.rows) {
        row[4]=.2*d[0]-.8*std::sin(a)+.3*std::cos(a)*std::sin(b);
        row[5]=.2*d[1]+.3*std::cos(b);
        row[6]=.2*d[2]+.8*std::cos(a)+.3*std::sin(a)*std::sin(b);
    }
    auto p=collectAeroSample(tilted,s,20,-15);
    check(p.isOk() && std::abs(p.value().cl-.8)<1e-12 && std::abs(p.value().cd-.2)<1e-12 && std::abs(p.value().cy-.3)<1e-12,"wind-axis decomposition at nonzero alpha and beta");
    // A point that ran to the end but did not settle is not a failed run: its fields exist and are
    // worth looking at. It is a computed point whose coefficients may not be used.
    auto unstable=converged(); unstable.history.rows.back()[5]+=0.1;
    auto verdict=collectAeroSample(unstable,s,0,0);
    check(verdict.isOk() && !verdict.value().usable(),"small pressure residual is insufficient while sideforce changes");
    unstable=converged(); unstable.history.rows.back()[2]=-2;
    verdict=collectAeroSample(unstable,s,0,0);
    check(verdict.isOk() && !verdict.value().usable(),"all velocity residuals must converge");
    unstable=converged(); unstable.exitStatus=1;
    check(!collectAeroSample(unstable,s,0,0).isOk(),"crashed solver cannot produce a result from history");
    check(!parseSu2History("a,b\n1,2garbage\n").isOk(),"trailing garbage in CSV refused");
    check(!parseSu2History("a,b\n1,nan\n").isOk(),"NaN in CSV refused");
    check(!parseSu2History("a,b\n1\n").isOk(),"truncated history refused");
    check(!parseSu2History("a,a\n1,2\n").isOk(),"duplicate history headers refused");
    check(std::isnan(converged().history.relativeSpread("CFx",100)),"a short history has no full convergence window");
    {
        auto transient=s;transient.model="urans_sst";transient.layerHeightsM={.001,.0015};transient.timeSteps=100;transient.innerIterations=20;transient.averagingSteps=40;transient.timeStepSeconds=.002;transient.residualTarget=-4;transient.coefficientAbsoluteTolerance=.002;transient.coefficientRelativeTolerance=.02;
        const auto config=aeroConfig(transient,0,0,{"wall"}).text();
        check(config.find("SOLVER= INC_RANS")!=std::string::npos&&config.find("TIME_DOMAIN= YES")!=std::string::npos&&config.find("TIME_MARCHING= DUAL_TIME_STEPPING-2ND_ORDER")!=std::string::npos&&config.find("TIME_ITER= 100")!=std::string::npos&&config.find("INNER_ITER= 20")!=std::string::npos,"URANS uses time-accurate incompressible RANS with dual-time stepping");
        Su2RunResult run;run.exitStatus=0;run.history.columns={"Time_Iter","Inner_Iter","rms[P]","rms[U]","rms[V]","rms[W]","rms[k]","rms[w]","CFx","CFy","CFz","CMx","CMy","CMz"};
        for(int step=0;step<100;++step)for(int inner:{0,19}){const double wave=.01*std::sin(step*2*std::acos(-1.)/10);run.history.rows.push_back({double(step),double(inner),-5,-5,-5,-5,-5,-5,.2+wave,0,.8-wave,0,.5,0});}
        auto averaged=collectAeroSample(run,transient,0,0);
        check(averaged.isOk()&&std::abs(averaged.value().cd-.2)<1e-9&&std::abs(averaged.value().cl-.8)<1e-9&&averaged.value().coefficientSpread>.019,"URANS accepts a stationary periodic wake and exports time-averaged coefficients");
        for(int step=60;step<100;++step)for(int inner=0;inner<2;++inner)run.history.rows[(step*2)+inner][8]+=.001*(step-60);
        const auto drifting=collectAeroSample(run,transient,0,0);
        check(drifting.isOk() && !drifting.value().usable(),"URANS rejects a drifting time average");
    }

    // Near-wall sizing: the correlations must be the ones the comments claim, and the stack must
    // reach the boundary layer.
    {
        const double speed=20,chord=0.4,density=1.225,viscosity=1.7894e-5;
        const double re=reynoldsNumber(speed,chord,density,viscosity);
        check(std::abs(re-density*speed*chord/viscosity)<1e-6,"Reynolds number of the reference chord");
        check(std::abs(flatPlateSkinFriction(re)-0.026*std::pow(re,-1.0/7.0))<1e-12,"flat-plate skin friction correlation");
        check(std::abs(boundaryLayerThicknessM(re,chord)-0.37*chord*std::pow(re,-0.2))<1e-12,"boundary layer thickness correlation");
        const double frictionVelocity=speed*std::sqrt(flatPlateSkinFriction(re)/2);
        const double first=heightForYPlus(1,speed,chord,density,viscosity);
        check(std::abs(first-viscosity/(density*frictionVelocity))<1e-15,"y+ = 1 height from the friction velocity");
        check(std::abs(yPlusForHeight(first,speed,chord,density,viscosity)-1)<1e-9,"height and y+ are inverse");
        const auto resolved=planWallLayers(WallTreatment::Resolved,speed,chord,density,viscosity);
        check(std::abs(resolved.firstHeightM-first)<1e-15 && resolved.totalHeightM>=resolved.boundaryLayerM,
              "resolved stack starts at y+ = 1 and covers the boundary layer");
        const auto functions=planWallLayers(WallTreatment::Functions,speed,chord,density,viscosity);
        check(std::abs(yPlusForHeight(functions.firstHeightM,speed,chord,density,viscosity)-50)<1e-6 &&
              functions.heightsM.size()<resolved.heightsM.size(),
              "wall-function stack starts in the log layer and needs fewer layers");
    }
    // The verdict on the near-wall mesh is measured from SU2's own y+, not promised by the settings.
    {
        auto surfaceWith=[](const std::vector<double>& yPlus) {
            Su2History table; table.columns={"x","Y_Plus"};
            for (double v:yPlus) table.rows.push_back({0,v});
            return table;
        };
        check(assessWallResolution(surfaceWith(std::vector<double>(100,0.8)),WallTreatment::Resolved).valid,
              "a resolved sublayer passes");
        auto buffer=assessWallResolution(surfaceWith(std::vector<double>(100,22.0)),WallTreatment::Resolved);
        check(!buffer.valid && buffer.problem.find("y+")!=std::string::npos,"the buffer layer fails a wall-resolved run");
        check(!assessWallResolution(surfaceWith(std::vector<double>(100,22.0)),WallTreatment::Functions).valid,
              "the buffer layer fails a wall-function run as well: no log law there yet");
        check(assessWallResolution(surfaceWith(std::vector<double>(100,60.0)),WallTreatment::Functions).valid,
              "the log layer is where wall functions apply");
        std::vector<double> mostlyResolved(100,0.8); for (int i=0;i<4;++i) mostlyResolved[i]=9;
        check(assessWallResolution(surfaceWith(mostlyResolved),WallTreatment::Resolved).valid,
              "a few edge nodes above y+ = 2 do not condemn a resolved mesh");
        std::vector<double> lowShear(100,60.0); for (int i=0;i<20;++i) lowShear[i]=0.5;
        check(assessWallResolution(surfaceWith(lowShear),WallTreatment::Functions).valid,
              "nodes below y+ = 5 near stagnation are handled by the viscous stress, not an error");
        check(!assessWallResolution(Su2History{},WallTreatment::Resolved).valid,"a run without y+ cannot claim a resolved wall");
    }
    // The omega residual's level is set by its wall boundary condition; only its fall means anything.
    {
        auto turbulent=s; turbulent.model="sst"; turbulent.speedMps=20; turbulent.reference={.48,1.2,.4,{0,0,0}};
        turbulent.densityKgM3=1.225; turbulent.viscosityPaS=1.7894e-5; turbulent.wallTreatment="resolved";
        turbulent.layerHeightsM=planWallLayers(WallTreatment::Resolved,turbulent.speedMps,turbulent.reference.chordM,
                                               turbulent.densityKgM3,turbulent.viscosityPaS).heightsM;
        Su2RunResult run; run.exitStatus=0;
        run.history.columns={"rms[P]","rms[U]","rms[V]","rms[W]","rms[k]","rms[w]","CFx","CFy","CFz","CMx","CMy","CMz"};
        for (int i=0;i<10;++i) run.history.rows.push_back({-8,-8,-8,-8,i?-6.5:-1.5,i?-2.4:1.8,0.2,0.3,0.8,0.4,0.5,0.6});
        Su2History surface; surface.columns={"Y_Plus"}; for (int i=0;i<50;++i) surface.rows.push_back({0.7});
        auto point=collectAeroSample(run,turbulent,0,0,surface);
        check(point.isOk() && point.value().usable(),"omega that fell four decades from its wall scale is converged");
        // The omega RMS can sit flat on a floor set by the far-field cells (measured on the wing: 91 %
        // of it in twelve box-edge nodes) while the forces have settled; it is reported, not judged.
        for (auto& row:run.history.rows) row[5]=1.38;
        point=collectAeroSample(run,turbulent,0,0,surface);
        check(point.isOk() && point.value().usable(),"a flat omega residual does not gate a point whose flow and forces have settled");
        for (auto& row:run.history.rows) row[5]=NAN;
        check(!collectAeroSample(run,turbulent,0,0,surface).isOk(),"a non-finite turbulence residual is still a failed run");
        for (auto& row:run.history.rows) row[5]=-2.4;
        for (auto& row:surface.rows) row[0]=22;
        point=collectAeroSample(run,turbulent,0,0,surface);
        check(point.isOk() && !point.value().usable() && !point.value().wall.valid,
              "a converged run on a buffer-layer mesh keeps its fields and loses its coefficients");
    }
    bad=s; bad.model="laminar"; bad.layerHeightsM={1e-4}; bad.speedMps=20; bad.reference={.48,1.2,.4,{0,0,0}};
    check(!validateAeroSettings(bad).empty(),"laminar flow is refused above Re = 5e5");
    bad.model="sst"; bad.wallTreatment="functions"; check(validateAeroSettings(bad).empty(),"wall functions are allowed for SST");
    bad.model="laminar"; bad.speedMps=1; check(!validateAeroSettings(bad).empty(),"wall functions have no meaning in laminar flow");
    bad.model="sst"; bad.wallTreatment="nothing"; check(!validateAeroSettings(bad).empty(),"unknown wall treatment refused");
    check(aeroConfig([&]{auto t=s;t.model="sst";t.wallTreatment="functions";t.layerHeightsM={1e-4};return t;}(),0,0,{"body_0"}).text()
              .find("MARKER_WALL_FUNCTIONS= ( body_0, STANDARD_WALL_FUNCTION )")!=std::string::npos,
          "the wall-function regime reaches the solver configuration");
    {
        auto lm=s; lm.model="sst"; lm.wallTreatment="resolved"; lm.layerHeightsM={1e-5,1.2e-5}; lm.transition="lm"; lm.turbulenceIntensity=0.003;
        check(validateAeroSettings(lm).empty(),"γ-Reθ transition on a resolved SST wall is accepted");
        const auto text=aeroConfig(lm,0,0,{"body_0"}).text();
        check(text.find("KIND_TRANS_MODEL= LM")!=std::string::npos && text.find("LM_OPTIONS= ( MENTER_LANGTRY )")!=std::string::npos,
              "the transition model reaches the solver configuration");
        check(text.find("SST_OPTIONS= ( V2003m, SUSTAINING )")!=std::string::npos,
              "transition runs with sustaining terms, so the Tu set is the Tu at the body");
        check(text.find("FREESTREAM_TURBULENCEINTENSITY= 0.003")!=std::string::npos,"the free-stream turbulence intensity set reaches the solver");
        auto plain=lm; plain.transition="none";
        const auto plainText=aeroConfig(plain,0,0,{"body_0"}).text();
        check(plainText.find("KIND_TRANS_MODEL")==std::string::npos && plainText.find("SUSTAINING")==std::string::npos,
              "without transition the verified SST configuration is unchanged");
        auto refused=lm; refused.wallTreatment="functions"; refused.layerHeightsM={1e-3};
        check(!validateAeroSettings(refused).empty(),"transition is refused on a wall-function mesh");
        refused=lm; refused.model="laminar"; refused.speedMps=1;
        check(!validateAeroSettings(refused).empty(),"transition is refused without a turbulence model");
        refused=lm; refused.transition="bl"; check(!validateAeroSettings(refused).empty(),"unknown transition model refused");
        refused=lm; refused.turbulenceIntensity=0; check(!validateAeroSettings(refused).empty(),"zero turbulence intensity refused");
        const auto parsed=parseAeroJob(std::string("{\"schema\":\"cadnext-aerodynamics-job/1\",\"solverPath\":\"x\",\"resultPath\":\"r.json\",\"workDirectory\":\"w\",")
            +"\"cadAxes\":{\"lengthUnit\":\"m\",\"forward\":\"+y\",\"up\":\"+z\"},\"geometry\":[{\"id\":\"b\",\"path\":\"b.brep\",\"sha256\":\""+std::string(64,'a')+"\"}],\"settings\":"+aeroSettingsJson(lm).serialize()+"}","/tmp");
        check(parsed.isOk() && parsed.value().settings.transition=="lm" && std::fabs(parsed.value().settings.turbulenceIntensity-0.003)<1e-12,
              "transition settings survive the job file", parsed.isOk()?"":parsed.error().message);
    }

    AeroJob job; job.settings=s;
    auto partial=aeroResultJson(job,{},"SU2 test","netgen test");
    check(partial.stringOr("outcome","")=="error" && !partial.member("aeroTable"),"partial series never exports a runtime table");
    auto complete=aeroResultJson(job,{result.value()},"SU2 test","netgen test");
    check(complete.stringOr("outcome","")=="warning" && complete.member("aeroTable"),"one mesh has unknown spatial error and remains WARNING");
    {
        AeroSample flawed=result.value(); flawed.problems.push_back("пограничный слой не разрешён");
        auto unusable=aeroResultJson(job,{flawed},"SU2 test","netgen test");
        check(unusable.stringOr("outcome","")=="warning" && !unusable.member("aeroTable"),
              "a computed but flawed point keeps its fields and never reaches the runtime table");
        check(!unusable.member("coefficientsUsable")->boolValue,"the result says plainly that the coefficients are not usable");
        const auto* reasons=unusable.member("failureReasons");
        check(reasons->arrayItems.size()==1 && reasons->arrayItems[0].stringValue.find("пограничный слой")!=std::string::npos,
              "the reason names the point and the physical problem");
    }
    job.settings.model="laminar"; job.settings.alphaDeg={0,10,20};
    AeroSample zero=result.value(), peak=zero, decline=zero;
    zero.cl=.1; peak.alphaDeg=10; peak.cl=1; decline.alphaDeg=20; decline.cl=.8;
    auto polar=aeroResultJson(job,{zero,peak,decline},"SU2 test","netgen test");
    const auto* metrics=polar.member("metrics");
    check(metrics->member("possibleStallLowerDeg")->numberOr("value",-1)==10 && metrics->member("possibleStallUpperDeg")->numberOr("value",-1)==20,
          "a resolved lift peak and subsequent drop bracket possible stall");
    decline.cl=1.1; polar=aeroResultJson(job,{zero,peak,decline},"SU2 test","netgen test");
    check(!polar.member("metrics")->member("possibleStallLowerDeg"),"a still-rising polar cannot claim a stall angle");

    // User-selected paths are argv and a working directory, never shell source.
    namespace fs=std::filesystem;
    const auto root=fs::temp_directory_path()/("cfd-path-"+std::to_string(getpid())+" ' $literal"); fs::create_directories(root);
    const auto executable=root/"fake solver ' $literal";
    { std::ofstream f(executable); f<<"#!/bin/sh\nprintf '\"rms[P]\",\"CFx\"\\n-8,0.1\\n' > history.csv\n"; }
    fs::permissions(executable,fs::perms::owner_all);
    auto run=runSu2(executable.string(),root.string(),{},1);
    check(run.isOk() && run.value().exitStatus==0 && run.value().history.last("CFx")==.1,"quoted and dollar paths launch literally");
    { std::ofstream f(executable); f<<"#!/bin/sh\nexit 3\n"; }
    run=runSu2(executable.string(),root.string(),{},1);
    check(run.isOk() && run.value().exitStatus==3 && run.value().history.empty(),"failed retry cannot collect stale history");
    { std::ofstream f(executable); f<<"#!/bin/sh\nsleep 20\n"; }
    Su2RunControl control; control.timeoutSeconds=.15;
    run=runSu2(executable.string(),root.string(),{},1,control);
    check(run.isOk() && run.value().timedOut,"timeout terminates solver process group");
    control.cancel=[] { return true; };
    run=runSu2(executable.string(),root.string(),{},1,control);
    check(run.isOk() && run.value().cancelled,"cancellation before spawn does not launch a process");
    fs::remove_all(root);
    return fea_test::finish("test_cfd_study");
}
