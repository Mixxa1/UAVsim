#include "fea_test_support.hpp"
#include "cadnext/cfd/AerodynamicStudy.hpp"
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
    auto s=settings(); check(validateAeroSettings(s).empty(),"complete settings accepted");
    auto bad=s; bad.speedMps=INFINITY; check(!validateAeroSettings(bad).empty(),"infinite flow speed refused");
    bad=s; bad.alphaDeg={0,0}; check(!validateAeroSettings(bad).empty(),"duplicate sweep angle refused");
    bad=s; bad.model="sst"; check(!validateAeroSettings(bad).empty(),"viscous study requires wall layers");
    bad=s; bad.convergenceWindow=101; check(!validateAeroSettings(bad).empty(),"iteration count must cover the convergence window");
    auto rotated=cadToSolver("+x","+z",{1,2,3});
    check(rotated.isOk() && rotated.value()==Point3{-1,-2,3},"CAD forward/up map to aft/right/up without reflection");
    check(!cadToSolver("+x","-x",{}).isOk(),"collinear CAD axes refused");
    auto result=collectAeroSample(converged(),s,0,0);
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
    auto unstable=converged(); unstable.history.rows.back()[5]+=0.1;
    check(!collectAeroSample(unstable,s,0,0).isOk(),"small pressure residual is insufficient while sideforce changes");
    unstable=converged(); unstable.history.rows.back()[2]=-2;
    check(!collectAeroSample(unstable,s,0,0).isOk(),"all velocity residuals must converge");
    unstable=converged(); unstable.exitStatus=1;
    check(!collectAeroSample(unstable,s,0,0).isOk(),"crashed solver cannot produce a result from history");
    check(!parseSu2History("a,b\n1,2garbage\n").isOk(),"trailing garbage in CSV refused");
    check(!parseSu2History("a,b\n1,nan\n").isOk(),"NaN in CSV refused");
    check(!parseSu2History("a,b\n1\n").isOk(),"truncated history refused");
    check(!parseSu2History("a,a\n1,2\n").isOk(),"duplicate history headers refused");
    check(std::isnan(converged().history.relativeSpread("CFx",100)),"a short history has no full convergence window");

    AeroJob job; job.settings=s;
    auto partial=aeroResultJson(job,{},"SU2 test","netgen test");
    check(partial.stringOr("outcome","")=="error" && !partial.member("aeroTable"),"partial series never exports a runtime table");
    auto complete=aeroResultJson(job,{result.value()},"SU2 test","netgen test");
    check(complete.stringOr("outcome","")=="warning" && complete.member("aeroTable"),"one mesh has unknown spatial error and remains WARNING");
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
