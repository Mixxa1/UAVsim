#include "cadnext/cfd/AerodynamicStudy.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <iomanip>
#include <locale>
#include <set>
#include <sstream>
#include <limits>

namespace cadnext::cfd {
namespace {
constexpr double pi = 3.14159265358979323846;
Json num(double v) { return Json::makeNumber(v); }
Json str(const std::string& v) { return Json::makeString(v); }
Json array(const std::vector<double>& values) { auto a = Json::makeArray(); for (double v : values) a.arrayItems.push_back(num(v)); return a; }
Json vector(const Point3& p) { return array({p[0], p[1], p[2]}); }
double dot(Point3 a, Point3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
Point3 cross(Point3 a, Point3 b) { return {a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]}; }
bool axis(const std::string& name, Point3& out) {
    if (name.size()!=2 || (name[0]!='+' && name[0]!='-') || name[1]<'x' || name[1]>'z') return false;
    out = {}; out[name[1]-'x'] = name[0]=='+' ? 1 : -1; return true;
}
std::string number(double v) { std::ostringstream o; o.imbue(std::locale::classic()); o << std::setprecision(17) << v; return o.str(); }
bool positive(double v) { return std::isfinite(v) && v > 0; }
}

std::string validateAeroSettings(const AeroSettings& s) {
    if (s.model != "euler" && s.model != "laminar" && s.model != "sst") return "неподдерживаемая модель течения";
    for (const auto* angles : {&s.alphaDeg, &s.betaDeg}) {
        if (angles->empty() || angles->size() > 181) return "нужен непустой диапазон углов (до 181 точки)";
        for (std::size_t i=0; i<angles->size(); ++i)
            if (!std::isfinite((*angles)[i]) || std::abs((*angles)[i]) > 75 || (i && (*angles)[i] <= (*angles)[i-1]))
                return "углы должны строго возрастать и лежать в диапазоне −75…75°";
    }
    if (s.alphaDeg.size()*s.betaDeg.size()>256) return "не более 256 расчётных точек";
    if (!positive(s.speedMps) || s.speedMps > 100 || !positive(s.densityKgM3) || !positive(s.viscosityPaS))
        return "нужны положительные скорость (до 100 м/с), плотность и вязкость; решатель несжимаемый";
    if (!positive(s.reference.areaM2) || !positive(s.reference.chordM) || !positive(s.reference.spanM)) return "задайте опорные площадь, размах и хорду";
    for (double v : s.reference.momentCenterModelM) if (!std::isfinite(v)) return "неверная точка отсчёта моментов";
    if (!positive(s.wallSizeM) || !positive(s.farfieldSizeM) || !positive(s.farfieldLengths) ||
        !positive(s.grading) || s.grading > 1) return "неверные размеры сетки, дальнего поля или grading";
    if (s.convergenceWindow < 5 || s.iterations < s.convergenceWindow + 2 || s.iterations > 1000000 || s.threads < 1 || s.threads > 256 ||
        !positive(s.timeoutSeconds) || !std::isfinite(s.residualTarget) || s.residualTarget > -3 || s.residualTarget < -15 ||
        !positive(s.coefficientAbsoluteTolerance) || !positive(s.coefficientRelativeTolerance)) return "неверные параметры сходимости, времени или потоков";
    if (s.model == "euler" && !s.layerHeightsM.empty()) return "для Euler призматические слои не используются";
    if (s.model != "euler" && s.layerHeightsM.empty()) return "вязкое течение требует призматических слоёв у стенки";
    double total = 0;
    for (double h : s.layerHeightsM) { if (!positive(h)) return "высота каждого слоя должна быть положительной"; total += h; }
    if (s.layerHeightsM.size() > 100 || total > s.farfieldLengths * s.reference.spanM) return "неверная суммарная толщина слоёв";
    return {};
}

Result<Point3> cadToSolver(const std::string& forward, const std::string& up, const Point3& p) {
    Point3 f{}, u{};
    if (!axis(forward, f) || !axis(up, u) || dot(f,u)!=0) return Result<Point3>::fail({ErrorCode::InvalidArgument,"CAD: нужны две перпендикулярные оси"});
    const auto r = cross(f,u);
    return Result<Point3>::ok({-dot(p,f), dot(p,r), dot(p,u)});
}
Point3 flowDirection(double alpha, double beta) {
    const double a=alpha*pi/180, b=beta*pi/180;
    return {std::cos(a)*std::cos(b), -std::sin(b), std::sin(a)*std::cos(b)};
}

Json aeroSettingsJson(const AeroSettings& s) {
    auto j=Json::makeObject();
    j.set("model",str(s.model)); j.set("alphaDeg",array(s.alphaDeg)); j.set("betaDeg",array(s.betaDeg));
    j.set("speedMps",num(s.speedMps)); j.set("densityKgM3",num(s.densityKgM3)); j.set("viscosityPaS",num(s.viscosityPaS));
    auto r=Json::makeObject(); r.set("areaM2",num(s.reference.areaM2)); r.set("spanM",num(s.reference.spanM)); r.set("chordM",num(s.reference.chordM));
    r.set("momentCenterModelM",vector(s.reference.momentCenterModelM)); j.set("reference",r);
    j.set("iterations",num(s.iterations)); j.set("convergenceWindow",num(s.convergenceWindow)); j.set("threads",num(s.threads));
    j.set("residualTarget",num(s.residualTarget)); j.set("coefficientAbsoluteTolerance",num(s.coefficientAbsoluteTolerance));
    j.set("coefficientRelativeTolerance",num(s.coefficientRelativeTolerance)); j.set("timeoutSeconds",num(s.timeoutSeconds));
    j.set("farfieldLengths",num(s.farfieldLengths)); j.set("wallSizeM",num(s.wallSizeM)); j.set("farfieldSizeM",num(s.farfieldSizeM));
    j.set("grading",num(s.grading)); j.set("layerHeightsM",array(s.layerHeightsM)); return j;
}

Result<AeroJob> parseAeroJob(const std::string& text, const std::string& base) {
    auto fail=[](const std::string& m){return Result<AeroJob>::fail({ErrorCode::InvalidArgument,m});};
    Json root; std::string error;
    if (!fea::json::parseJson(text,root,error) || !root.isObject()) return fail("неверный JSON задания CFD: "+error);
    if (root.stringOr("schema","")!="cadnext-aerodynamics-job/1") return fail("неподдерживаемая схема задания CFD");
    AeroJob job;
    auto path=[&](const std::string& value) { return value.empty() ? value : (std::filesystem::path(base)/value).lexically_normal().string(); };
    job.solverPath=path(root.stringOr("solverPath","")); job.resultPath=path(root.stringOr("resultPath","result.json"));
    job.workDirectory=path(root.stringOr("workDirectory","flow"));
    const auto* axes=root.member("cadAxes");
    if (!axes || axes->stringOr("lengthUnit","")!="m") return fail("нужны оси CAD и единицы m");
    job.cadForward=axes->stringOr("forward",""); job.cadUp=axes->stringOr("up","");
    if (!cadToSolver(job.cadForward,job.cadUp,{}).isOk()) return fail("неверные оси CAD");
    const auto* geometry=root.member("geometry");
    if (!geometry || !geometry->isArray() || geometry->arrayItems.empty()) return fail("нет точной геометрии");
    std::set<std::string> ids;
    for (const auto& g : geometry->arrayItems) {
        AeroGeometry item{g.stringOr("id",""),path(g.stringOr("path","")),g.stringOr("sha256","")};
        if (item.id.empty() || !ids.insert(item.id).second || item.path.empty() || item.sha256.size()!=64 ||
            item.sha256.find_first_not_of("0123456789abcdef")!=std::string::npos) return fail("неверная геометрия, идентификатор или SHA-256");
        job.geometry.push_back(item);
    }
    if (const auto* proxies=root.member("proxies")) {
        if (!proxies->isArray() || proxies->arrayItems.size()>1000) return fail("неверный список внешних компонентов");
        for (const auto& p:proxies->arrayItems) {
            AeroProxy item; item.id=p.stringOr("id","");
            if (item.id.empty() || !ids.insert(item.id).second) return fail("повторный идентификатор внешнего компонента");
            for (const auto& [key,dest]:std::vector<std::pair<std::string,Point3*>>{{"centerModelM",&item.centerModelM},{"sizeModelM",&item.sizeModelM}}) {
                const auto* v=p.member(key);
                if (!v || !v->isArray() || v->arrayItems.size()!=3) return fail("неверные габариты внешнего компонента");
                for (int i=0;i<3;++i) {
                    if (v->arrayItems[i].type!=Json::Type::Number || !std::isfinite(v->arrayItems[i].numberValue)) return fail("нечисловой габарит компонента");
                    (*dest)[i]=v->arrayItems[i].numberValue;
                }
            }
            for (double d:item.sizeModelM) if (!positive(d)) return fail("нулевой габарит компонента");
            job.proxies.push_back(item);
        }
    }
    const auto* settings=root.member("settings");
    if (!settings || !settings->isObject()) return fail("нет настроек CFD");
    auto& s=job.settings;
    s.model=settings->stringOr("model","");
    auto take=[&](const Json& object,const char* key,double& value) {
        const auto* v=object.member(key);
        if (v && v->type==Json::Type::Number) value=v->numberValue;
        else error="нет числового поля "+std::string(key);
    };
    auto integer=[&](const char* key,int& value) {
        double d=0; take(*settings,key,d);
        if (!std::isfinite(d) || d!=std::floor(d) || d<0 || d>1000000) error="неверное целое поле "+std::string(key);
        else value=static_cast<int>(d);
    };
    auto list=[&](const Json& object,const char* key,std::vector<double>& values) {
        const auto* v=object.member(key); values.clear();
        if (!v || !v->isArray()) { error="нет массива "+std::string(key); return; }
        for (const auto& item:v->arrayItems) {
            if (item.type!=Json::Type::Number) error="нечисловой элемент "+std::string(key);
            else values.push_back(item.numberValue);
        }
    };
    list(*settings,"alphaDeg",s.alphaDeg); list(*settings,"betaDeg",s.betaDeg); list(*settings,"layerHeightsM",s.layerHeightsM);
    take(*settings,"speedMps",s.speedMps); take(*settings,"densityKgM3",s.densityKgM3); take(*settings,"viscosityPaS",s.viscosityPaS);
    take(*settings,"farfieldLengths",s.farfieldLengths); take(*settings,"wallSizeM",s.wallSizeM); take(*settings,"farfieldSizeM",s.farfieldSizeM); take(*settings,"grading",s.grading);
    take(*settings,"residualTarget",s.residualTarget); take(*settings,"timeoutSeconds",s.timeoutSeconds);
    take(*settings,"coefficientAbsoluteTolerance",s.coefficientAbsoluteTolerance); take(*settings,"coefficientRelativeTolerance",s.coefficientRelativeTolerance);
    integer("iterations",s.iterations); integer("threads",s.threads); integer("convergenceWindow",s.convergenceWindow);
    const auto* r=settings->member("reference");
    if (!r || !r->isObject()) return fail("нет опорных размеров");
    take(*r,"areaM2",s.reference.areaM2); take(*r,"spanM",s.reference.spanM); take(*r,"chordM",s.reference.chordM);
    std::vector<double> center; list(*r,"momentCenterModelM",center);
    if (center.size()!=3) return fail("точка момента должна содержать три координаты");
    std::copy(center.begin(),center.end(),s.reference.momentCenterModelM.begin());
    if (!error.empty()) return fail(error);
    error=validateAeroSettings(s); if (!error.empty()) return fail(error);
    if (job.solverPath.empty()) return fail("не задан путь SU2_CFD");
    return Result<AeroJob>::ok(job);
}

Su2Config aeroConfig(const AeroSettings& s,double alpha,double beta,const std::vector<std::string>& walls) {
    Su2Config c;
    for (const auto& [key,value] : std::vector<std::pair<std::string,std::string>>{
        {"SOLVER",s.model=="euler" ? "INC_EULER" : s.model=="laminar" ? "INC_NAVIER_STOKES" : "INC_RANS"},
        {"MATH_PROBLEM","DIRECT"},{"INC_DENSITY_MODEL","CONSTANT"},{"INC_ENERGY_EQUATION","NO"},
        {"INC_NONDIM","INITIAL_VALUES"},{"NUM_METHOD_GRAD","WEIGHTED_LEAST_SQUARES"},
        {"CONV_NUM_METHOD_FLOW","FDS"},{"MUSCL_FLOW","YES"},{"SLOPE_LIMITER_FLOW","VENKATAKRISHNAN"},
        {"TIME_DISCRE_FLOW","EULER_IMPLICIT"},{"CFL_NUMBER","5"},{"CFL_ADAPT","YES"},{"CFL_ADAPT_PARAM","( 0.5, 1.5, 1.0, 100.0 )"},
        {"LINEAR_SOLVER","FGMRES"},{"LINEAR_SOLVER_PREC","ILU"},{"LINEAR_SOLVER_ERROR","1E-4"},{"LINEAR_SOLVER_ITER","20"},
        {"MESH_FILENAME","mesh.su2"},{"MESH_FORMAT","SU2"},{"TABULAR_FORMAT","CSV"},{"CONV_FILENAME","history"},
        {"SURFACE_FILENAME","surface"},{"VOLUME_FILENAME","volume"},
        {"HISTORY_OUTPUT","( ITER, RMS_RES, AERO_COEFF, AERO_COEFF_SURF )"},
        {"WRT_RESTART_COMPACT","NO"},{"HISTORY_WRT_FREQ_INNER","1"},{"OUTPUT_FILES","( SURFACE_CSV, PARAVIEW )"},
        {"VOLUME_OUTPUT","( COORDINATES, SOLUTION, PRIMITIVE )"},{"SCREEN_WRT_FREQ_INNER","50"}}) c.set(key,value);
    c.set("ITER",number(s.iterations));
    // The collector requires both residuals and a full force/moment stability window. A solver
    // stop on pressure alone would cut that window short. Retain the complete requested history.
    c.set("CONV_STARTITER",number(s.iterations+1));
    c.set("INC_DENSITY_INIT",number(s.densityKgM3));
    const auto d=flowDirection(alpha,beta);
    c.set("INC_VELOCITY_INIT","( "+number(d[0]*s.speedMps)+", "+number(d[1]*s.speedMps)+", "+number(d[2]*s.speedMps)+" )");
    c.set("REF_AREA",number(s.reference.areaM2)); c.set("REF_LENGTH",number(s.reference.chordM));
    const auto& p=s.reference.momentCenterModelM;
    c.set("REF_ORIGIN_MOMENT_X",number(-p[2])); c.set("REF_ORIGIN_MOMENT_Y",number(-p[0])); c.set("REF_ORIGIN_MOMENT_Z",number(p[1]));
    std::string names, heated;
    for (const auto& w:walls) { names+=(names.empty()?"":", ")+w; heated+=(heated.empty()?"":", ")+w+", 0.0"; }
    c.set("MARKER_FAR","( farfield )"); c.set("MARKER_MONITORING","( "+names+" )"); c.set("MARKER_PLOTTING","( "+names+" )");
    if (s.model=="euler") c.set("MARKER_EULER","( "+names+" )");
    else {
        c.set("MARKER_HEATFLUX","( "+heated+" )"); c.set("VISCOSITY_MODEL","CONSTANT_VISCOSITY"); c.set("MU_CONSTANT",number(s.viscosityPaS));
        if (s.model=="sst") { c.set("KIND_TURB_MODEL","SST"); c.set("FREESTREAM_TURBULENCEINTENSITY","0.01"); c.set("FREESTREAM_TURB2LAMVISCRATIO","10"); }
    }
    return c;
}

Result<AeroSample> collectAeroSample(const Su2RunResult& run,const AeroSettings& s,double alpha,double beta) {
    auto fail=[](const std::string& m){ return Result<AeroSample>::fail({ErrorCode::KernelOperationFailed,m}); };
    if (run.cancelled) return fail("расчёт отменён");
    if (run.timedOut) return fail("истекло время расчёта");
    if (run.exitStatus!=0) return fail("SU2 завершился с кодом "+std::to_string(run.exitStatus)+"; см. su2.log");
    const auto& h=run.history;
    if (h.rows.size()<static_cast<std::size_t>(s.convergenceWindow)) return fail("слишком короткая история для проверки сходимости");
    AeroSample out; out.alphaDeg=alpha; out.betaDeg=beta; out.iterations=static_cast<int>(h.rows.size()); out.residual=-100;
    std::vector<std::string> residuals{"rms[P]","rms[U]","rms[V]","rms[W]"};
    if (s.model=="sst") { residuals.push_back("rms[k]"); residuals.push_back("rms[w]"); }
    for (const auto& key:residuals) {
        const double r=h.last(key);
        if (!std::isfinite(r)) return fail("нет конечной невязки "+key);
        out.residual=std::max(out.residual,r);
        if (r>s.residualTarget) return fail("не достигнута сходимость: "+key+" = "+number(r));
    }
    for (const auto* key:{"CFx","CFy","CFz","CMx","CMy","CMz"}) {
        const int c=h.column(key);
        if (c<0 || !std::isfinite(h.last(key))) return fail(std::string("нет коэффициента ")+key);
        double low=h.last(key), high=low;
        for (std::size_t i=h.rows.size()-s.convergenceWindow;i<h.rows.size();++i) {
            if (h.rows[i].size()<=static_cast<std::size_t>(c) || !std::isfinite(h.rows[i][c])) return fail("повреждена история коэффициентов");
            low=std::min(low,h.rows[i][c]); high=std::max(high,h.rows[i][c]);
        }
        out.coefficientSpread=std::max(out.coefficientSpread,high-low);
        if (high-low>s.coefficientAbsoluteTolerance+s.coefficientRelativeTolerance*std::abs(h.last(key)))
            return fail(std::string("силы/моменты ещё меняются: ")+key);
    }
    const double a=alpha*pi/180,b=beta*pi/180;
    const Point3 f{h.last("CFx"),h.last("CFy"),h.last("CFz")};
    out.cd=dot(f,flowDirection(alpha,beta)); out.cl=dot(f,{-std::sin(a),0,std::cos(a)});
    out.cy=dot(f,{std::cos(a)*std::sin(b),std::cos(b),std::sin(a)*std::sin(b)});
    out.cm=h.last("CMy"); out.cRoll=h.last("CMx")*s.reference.chordM/s.reference.spanM;
    out.cYaw=h.last("CMz")*s.reference.chordM/s.reference.spanM;
    if (out.cd<0) return fail("отрицательное сопротивление: проверьте сетку и сходимость");
    return Result<AeroSample>::ok(out);
}

Json aeroSampleJson(const AeroSample& s) {
    auto j=Json::makeObject();
    j.set("alphaDeg",num(s.alphaDeg)); j.set("betaDeg",num(s.betaDeg)); j.set("cl",num(s.cl)); j.set("cd",num(s.cd)); j.set("cm",num(s.cm));
    j.set("cy",num(s.cy)); j.set("cRoll",num(s.cRoll)); j.set("cYaw",num(s.cYaw));
    j.set("iterations",num(s.iterations)); j.set("residual",num(s.residual)); j.set("coefficientSpread",num(s.coefficientSpread));
    j.set("directory",str(s.directory)); return j;
}
Json aeroResultJson(const AeroJob& job,const std::vector<AeroSample>& samples,const std::string& version,const std::string& mesher,const std::string& error) {
    auto r=Json::makeObject(); r.set("schema",str("cadnext-aerodynamics-result/1")); r.set("testType",str("aerodynamics"));
    const bool complete=error.empty() && samples.size()==job.settings.alphaDeg.size()*job.settings.betaDeg.size();
    r.set("outcome",str(complete?"warning":"error")); r.set("solverID",str("cadnext-su2")); r.set("solverVersion",str(version));
    auto settings=aeroSettingsJson(job.settings); settings.set("mesherVersion",str(mesher));
    settings.set("cadForward",str(job.cadForward)); settings.set("cadUp",str(job.cadUp));
    auto geometry=Json::makeArray(); for (const auto& g:job.geometry) { auto v=Json::makeObject(); v.set("id",str(g.id)); v.set("sha256",str(g.sha256)); geometry.arrayItems.push_back(v); }
    settings.set("geometry",geometry);
    auto proxies=Json::makeArray(); for (const auto& p:job.proxies) {
        auto v=Json::makeObject(); v.set("id",str(p.id)); v.set("centerModelM",vector(p.centerModelM)); v.set("sizeModelM",vector(p.sizeModelM)); proxies.arrayItems.push_back(v);
    }
    settings.set("proxies",proxies);
    auto units=Json::makeObject(); units.set("velocityScaleMps",num(job.settings.speedMps));
    units.set("gaugePressureScalePa",num(job.settings.densityKgM3*job.settings.speedMps*job.settings.speedMps));
    units.set("description",str("SU2 volume/surface files: velocity / Vinf, gauge pressure / (rhoinf Vinf^2); report surface velocities are m/s."));
    settings.set("fieldNormalization",units); r.set("settings",settings);
    auto warnings=Json::makeArray();
    if (complete) {
        if (!job.proxies.empty()) warnings.arrayItems.push_back(str("Внешние компоненты рассчитаны как габаритные параллелепипеды; их обводы приближены."));
        warnings.arrayItems.push_back(str("Одна сетка: погрешность дискретизации и влияние дальнего поля не оценены."));
        warnings.arrayItems.push_back(str("Стационарное несжимаемое течение, фиксированные Re; рули и обдув винтов не рассчитаны."));
        if (job.settings.model=="euler") warnings.arrayItems.push_back(str("Euler: нет трения и вязкого срыва. Только диагностика; таблица не допускается в физику."));
        if (job.settings.alphaDeg.size()==1) warnings.arrayItems.push_back(str("Одиночный угол атаки не задаёт полярную кривую для полёта."));
        if (job.settings.betaDeg.size()==1) warnings.arrayItems.push_back(str("Зависимость от скольжения не рассчитана; в полёте боковые производные берутся из профиля."));
    }
    r.set("warnings",warnings); auto failures=Json::makeArray(); if (!complete) failures.arrayItems.push_back(str(error.empty()?"серия не завершена":error)); r.set("failureReasons",failures);
    auto metrics=Json::makeObject(); auto metric=[&](const char* key,double value,const char* unit) { auto m=Json::makeObject(); m.set("value",num(value)); m.set("unit",str(unit)); metrics.set(key,m); };
    metric("completedPoints",static_cast<double>(samples.size()),"1"); metric("requestedPoints",job.settings.alphaDeg.size()*job.settings.betaDeg.size(),"1");
    if (complete) {
        const auto best=std::max_element(samples.begin(),samples.end(),[](const auto& a,const auto& b){return a.cl<b.cl;});
        metric("maximumLiftCoefficient",best->cl,"1"); metric("referenceAreaM2",job.settings.reference.areaM2,"m2");
        // A sampled drop after the positive-alpha peak brackets possible stall. It is
        // evidence from a steady polar, not a claim about unsteady stall onset or safety.
        std::vector<AeroSample> neutral;
        for (const auto& sample:samples) if (sample.betaDeg==0 && sample.alphaDeg>=0) neutral.push_back(sample);
        if (job.settings.model!="euler" && !neutral.empty()) {
            const auto peak=std::max_element(neutral.begin(),neutral.end(),[](const auto& a,const auto& b){return a.cl<b.cl;});
            metric("sampledPeakAlphaDeg",peak->alphaDeg,"deg");
            if (peak->cl>0) for (auto after=std::next(peak);after!=neutral.end();++after) {
                if (peak->cl-after->cl>=std::max(0.001,0.02*std::abs(peak->cl))) {
                    metric("possibleStallLowerDeg",peak->alphaDeg,"deg");
                    metric("possibleStallUpperDeg",after->alphaDeg,"deg");
                    break;
                }
            }
        }
    }
    r.set("metrics",metrics); r.set("fieldRef",str("report.html"));
    auto points=Json::makeArray(); for (const auto& sample:samples) points.arrayItems.push_back(aeroSampleJson(sample)); r.set("points",points);
    if (complete) {
        auto table=Json::makeObject(); table.set("schema",str("uavsim-aerodynamics/1"));
        table.set("frame",str("flight-body-rhu")); table.set("reference",*settings.member("reference"));
        table.set("speedMps",num(job.settings.speedMps)); table.set("densityKgM3",num(job.settings.densityKgM3)); table.set("viscosityPaS",num(job.settings.viscosityPaS));
        table.set("model",str(job.settings.model)); table.set("alphaDeg",array(job.settings.alphaDeg)); table.set("betaDeg",array(job.settings.betaDeg));
        table.set("points",points); r.set("aeroTable",table);
    }
    return r;
}
std::string aeroCapabilitiesJson() {
    return R"({"schema":"cadnext-aerodynamics-capabilities/1","adapterVersion":"1","solver":"SU2","models":["euler","laminar","sst"],"modes":["singlePoint","alphaSweep","betaSweep","alphaBetaSweep"],"steady":true,"compressible":false,"maxSpeedMps":100,"controlSurfaceSweep":false,"propwash":false,"gridUncertainty":false,"cancel":true,"fields":["pressure","velocity"],"geometry":"brep-ascii-metres"})";
}
} // namespace cadnext::cfd
