#include "cadnext/cfd/AerodynamicStudy.hpp"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <iomanip>
#include <locale>
#include <set>
#include <map>
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
// Three significant digits: numbers that a person reads in a message, not values that round-trip.
std::string brief(double v) { std::ostringstream o; o.imbue(std::locale::classic()); o << std::setprecision(3) << v; return o.str(); }
bool positive(double v) { return std::isfinite(v) && v > 0; }
}

std::string validateAeroSettings(const AeroSettings& s) {
    if (s.model != "euler" && s.model != "laminar" && s.model != "sst" && s.model != "urans_sst") return "неподдерживаемая модель течения";
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
    if (isUnsteady(s) && (!positive(s.timeStepSeconds) || s.timeStepSeconds > 10 || s.timeSteps < 10 || s.timeSteps > 100000 ||
        s.innerIterations < 2 || s.innerIterations > 10000 || s.averagingSteps < 5 || s.averagingSteps > s.timeSteps/2))
        return "URANS: проверьте физический шаг, число временных/внутренних шагов и окно усреднения";
    if (s.model == "euler" && !s.layerHeightsM.empty()) return "для Euler призматические слои не используются";
    if (s.model != "euler" && s.layerHeightsM.empty()) return "вязкое течение требует призматических слоёв у стенки";
    WallTreatment treatment{};
    if (!parseWallTreatment(s.wallTreatment, treatment)) return "wallTreatment: resolved или functions";
    // Wall functions are a turbulence-model construction: there is no log layer in laminar flow and
    // no wall to model in an inviscid one.
    if (treatment == WallTreatment::Functions && !isTurbulent(s)) return "пристеночные функции существуют только для турбулентных моделей (sst, urans_sst)";
    if (s.transition != "none" && s.transition != "lm") return "transition: none или lm";
    if (s.transition == "lm" && !isTurbulent(s)) return "модель перехода γ-Reθ работает поверх SST: выберите sst или urans_sst";
    // γ-Reθ transports intermittency through the laminar part of the layer and triggers on the
    // vorticity Reynolds number there; a wall-function mesh has no laminar layer to carry it.
    if (s.transition == "lm" && treatment != WallTreatment::Resolved) return "модели перехода нужен разрешённый пограничный слой (y+ ≈ 1), не пристеночные функции";
    if (!std::isfinite(s.turbulenceIntensity) || s.turbulenceIntensity <= 0 || s.turbulenceIntensity > 0.2)
        return "интенсивность турбулентности набегающего потока — доля от 0 до 0.2";
    // Above Re ≈ 5·10^5 a laminar solution is not a coarse answer, it is a different flow: the real
    // boundary layer has long since gone turbulent, and laminar friction and separation are wrong by
    // a factor, not a percentage. Below that the answer depends on the shape, so it is a warning.
    if (s.model == "laminar" && aeroReynolds(s) > 5e5) return "ламинарная модель при Re > 5·10^5 неприменима: возьмите SST или URANS";
    double total = 0;
    for (double h : s.layerHeightsM) { if (!positive(h)) return "высота каждого слоя должна быть положительной"; total += h; }
    if (s.layerHeightsM.size() > 100 || total > s.farfieldLengths * s.reference.spanM) return "неверная суммарная толщина слоёв";
    return {};
}

double aeroReynolds(const AeroSettings& s) {
    return reynoldsNumber(s.speedMps, s.reference.chordM, s.densityKgM3, s.viscosityPaS);
}

std::vector<std::string> aeroSetupProblems(const AeroSettings& s, bool wallMeasured) {
    std::vector<std::string> problems;
    if (s.model == "euler") return problems;
    const double reynolds = aeroReynolds(s);
    double total = 0;
    for (double h : s.layerHeightsM) total += h;
    if (s.model == "laminar") {
        if (reynolds > 1e5)
            problems.push_back("ламинарная модель при Re = " + brief(reynolds)
                               + " по хорде: выше 10^5 трение и отрыв определяет переход к турбулентности");
        // Below Re ≈ 10^3 there is no thin layer to resolve: the viscous region is the size of the
        // body and the ordinary mesh covers it. Above it, the Blasius layer must fit inside the
        // prisms, and ten cells across it is the usual minimum for a resolved velocity profile.
        const double layer = laminarBoundaryLayerThicknessM(reynolds, s.reference.chordM);
        if (reynolds >= 1e3 && layer > 0) {
            if (total < layer)
                problems.push_back("призматические слои (" + brief(total) + " м) тоньше ламинарного пограничного слоя ("
                                   + brief(layer) + " м)");
            if (s.layerHeightsM.size() < 10)
                problems.push_back("ламинарный пограничный слой разрешён " + std::to_string(s.layerHeightsM.size())
                                   + " слоями: для профиля скорости нужно не меньше десяти");
        }
        return problems;
    }
    WallTreatment treatment{};
    if (!parseWallTreatment(s.wallTreatment, treatment) || s.layerHeightsM.empty()) return problems;
    const auto plan = planWallLayers(treatment, s.speedMps, s.reference.chordM, s.densityKgM3, s.viscosityPaS);
    const std::string advice = "; для этой скорости первый слой " + brief(plan.firstHeightM) + " м, слоёв "
                               + std::to_string(plan.heightsM.size());
    // The estimate only speaks when the run itself did not: a measured y+ beats a flat-plate
    // correlation, and repeating both as two problems says the same thing twice.
    if (!wallMeasured) {
        const double expected = yPlusForHeight(s.layerHeightsM.front(), s.speedMps, s.reference.chordM, s.densityKgM3, s.viscosityPaS);
        if (treatment == WallTreatment::Resolved && expected > 2.0)
            problems.push_back("оценка y+ первого слоя ≈ " + brief(expected) + " при требуемом ≈ 1" + advice);
        if (treatment == WallTreatment::Functions && (expected < 15.0 || expected > 600.0))
            problems.push_back("оценка y+ первого слоя ≈ " + brief(expected) + " вне диапазона пристеночных функций 30…300" + advice);
    }
    // The turbulent thickness correlation is a flat-plate result and means nothing below Re ≈ 10^5;
    // there the measured y+ is the only near-wall statement worth making.
    if (reynolds >= 1e5 && total < plan.boundaryLayerM)
        problems.push_back("призматические слои (" + brief(total) + " м) тоньше пограничного слоя (" + brief(plan.boundaryLayerM)
                           + " м): внешняя часть слоя попадает в тетраэдры" + advice);
    return problems;
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
    j.set("model",str(s.model)); j.set("wallTreatment",str(s.wallTreatment)); j.set("transition",str(s.transition));
    j.set("turbulenceIntensity",num(s.turbulenceIntensity)); j.set("alphaDeg",array(s.alphaDeg)); j.set("betaDeg",array(s.betaDeg));
    j.set("speedMps",num(s.speedMps)); j.set("densityKgM3",num(s.densityKgM3)); j.set("viscosityPaS",num(s.viscosityPaS));
    auto r=Json::makeObject(); r.set("areaM2",num(s.reference.areaM2)); r.set("spanM",num(s.reference.spanM)); r.set("chordM",num(s.reference.chordM));
    r.set("momentCenterModelM",vector(s.reference.momentCenterModelM)); j.set("reference",r);
    j.set("iterations",num(s.iterations)); j.set("convergenceWindow",num(s.convergenceWindow)); j.set("threads",num(s.threads));
    j.set("timeSteps",num(s.timeSteps)); j.set("innerIterations",num(s.innerIterations)); j.set("averagingSteps",num(s.averagingSteps));
    j.set("timeStepSeconds",num(s.timeStepSeconds));
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
    s.wallTreatment=settings->stringOr("wallTreatment","resolved");
    s.transition=settings->stringOr("transition","none");
    if (const auto* tu=settings->member("turbulenceIntensity")) {
        if (tu->type!=Json::Type::Number) return fail("turbulenceIntensity — число");
        s.turbulenceIntensity=tu->numberValue;
    }
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
    // Time-accurate fields are required for URANS and meaningless for a steady run, so a steady job
    // may leave them out. validateAeroSettings still checks them whenever the model is unsteady.
    if (s.model=="urans_sst") {
        integer("timeSteps",s.timeSteps); integer("innerIterations",s.innerIterations); integer("averagingSteps",s.averagingSteps);
        take(*settings,"timeStepSeconds",s.timeStepSeconds);
    } else {
        for (const auto& [key,value]:std::vector<std::pair<const char*,int*>>{{"timeSteps",&s.timeSteps},{"innerIterations",&s.innerIterations},{"averagingSteps",&s.averagingSteps}})
            if (settings->member(key)!=nullptr) integer(key,*value);
        if (settings->member("timeStepSeconds")!=nullptr) take(*settings,"timeStepSeconds",s.timeStepSeconds);
    }
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
        {"WRT_RESTART_COMPACT","NO"},{"HISTORY_WRT_FREQ_INNER","1"},{"OUTPUT_FILES","( SURFACE_CSV, PARAVIEW, RESTART_ASCII )"},{"RESTART_FILENAME","volume"},
        {"VOLUME_OUTPUT","( COORDINATES, SOLUTION, PRIMITIVE )"},{"SCREEN_WRT_FREQ_INNER","50"}}) c.set(key,value);
    // URANS: about a hundred frames over the run, so that shedding at a few frames per period can
    // still be followed; each frame is reduced to the viewing section as soon as it is written
    // (SectionFrames.hpp), which is what makes that many affordable.
    const int fieldFrequency=isUnsteady(s)?std::max(1,s.timeSteps/100):std::max(25,s.iterations/20);
    c.set("OUTPUT_WRT_FREQ","( "+std::to_string(fieldFrequency)+", "+std::to_string(fieldFrequency)+", "+std::to_string(fieldFrequency)+" )");
    if (isUnsteady(s)) {
        c.set("TIME_DOMAIN","YES"); c.set("TIME_MARCHING","DUAL_TIME_STEPPING-2ND_ORDER");
        c.set("TIME_STEP",number(s.timeStepSeconds)); c.set("TIME_ITER",number(s.timeSteps));
        c.set("INNER_ITER",number(s.innerIterations)); c.set("MAX_TIME",number(s.timeStepSeconds*s.timeSteps));
        c.set("HISTORY_WRT_FREQ_TIME","1"); c.set("SCREEN_WRT_FREQ_TIME","1");
        c.set("CONV_STARTITER",number(s.innerIterations+1));
    } else c.set("ITER",number(s.iterations));
    // The collector requires both residuals and a full force/moment stability window. A solver
    // stop on pressure alone would cut that window short. Retain the complete requested history.
    if (!isUnsteady(s)) c.set("CONV_STARTITER",number(s.iterations+1));
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
        if (isTurbulent(s)) {
            c.set("KIND_TURB_MODEL","SST"); c.set("FREESTREAM_TURBULENCEINTENSITY",number(s.turbulenceIntensity)); c.set("FREESTREAM_TURB2LAMVISCRATIO","10");
            // γ-Reθ reads the turbulence intensity from the local k, and plain SST lets k decay on
            // the way from the inlet: with a far field a few chords out, 1 % at the boundary arrives
            // at the leading edge as ~0.2 %, and the transition would sit where that Tu puts it.
            // Sustaining terms hold the ambient k and ω where nothing produces turbulence, so the Tu
            // the user set is the Tu the boundary layer sees; inside the layer they are negligible.
            if (s.transition=="lm") {
                c.set("KIND_TRANS_MODEL","LM"); c.set("LM_OPTIONS","( MENTER_LANGTRY )");
                c.set("SST_OPTIONS","( V2003m, SUSTAINING )");
            }
            WallTreatment treatment{};
            if (parseWallTreatment(s.wallTreatment,treatment) && treatment==WallTreatment::Functions) {
                std::string functions;
                for (const auto& w:walls) functions+=(functions.empty()?"":", ")+w+", STANDARD_WALL_FUNCTION";
                c.set("MARKER_WALL_FUNCTIONS","( "+functions+" )");
            }
        }
    }
    return c;
}

Result<AeroSample> collectAeroSample(const Su2RunResult& run,const AeroSettings& s,double alpha,double beta,const Su2History& surface) {
    auto fail=[](const std::string& m){ return Result<AeroSample>::fail({ErrorCode::KernelOperationFailed,m}); };
    if (run.cancelled) return fail("расчёт отменён");
    if (run.timedOut) return fail("истекло время расчёта");
    if (run.exitStatus!=0) {
        // The solver's own last words are worth more than its exit code.
        std::string reason;
        for (const auto* marker:{"SU2 has diverged","Error in"}) {
            const auto at=run.log.rfind(marker);
            if (at==std::string::npos) continue;
            reason=run.log.substr(at,run.log.find('\n',at)-at);
            break;
        }
        return fail("SU2 завершился с кодом "+std::to_string(run.exitStatus)+(reason.empty()?"":": "+reason)+"; см. su2.log");
    }
    const auto& h=run.history;
    std::vector<std::size_t> representativeRows,firstRows;
    if (isUnsteady(s)) {
        const int timeColumn=h.column("Time_Iter");
        if (timeColumn<0) return fail("URANS: в истории SU2 нет физических временных шагов");
        for(std::size_t row=0;row<h.rows.size();++row) {
            if(h.rows[row].size()<=static_cast<std::size_t>(timeColumn))return fail("URANS: повреждена история временных шагов");
            if(representativeRows.empty() || h.rows[representativeRows.back()][timeColumn]!=h.rows[row][timeColumn]) { representativeRows.push_back(row);firstRows.push_back(row); }
            else representativeRows.back()=row; // last (best-converged) inner iteration of this time step
        }
        if(representativeRows.size()<static_cast<std::size_t>(s.averagingSteps))
            return fail("URANS: рассчитано недостаточно физических шагов для усреднения");
        representativeRows.erase(representativeRows.begin(),representativeRows.end()-s.averagingSteps);
        firstRows.erase(firstRows.begin(),firstRows.end()-s.averagingSteps);
    } else {
        if (h.rows.size()<static_cast<std::size_t>(s.convergenceWindow)) return fail("слишком короткая история для проверки сходимости");
        for(std::size_t row=h.rows.size()-s.convergenceWindow;row<h.rows.size();++row)representativeRows.push_back(row);
    }
    AeroSample out; out.alphaDeg=alpha; out.betaDeg=beta;
    out.iterations=isUnsteady(s)?static_cast<int>(std::llround(h.rows[representativeRows.back()][h.column("Time_Iter")]))+1:static_cast<int>(h.rows.size()); out.residual=-100;
    // Only the flow equations gate a point. The k and omega residuals are reported, not judged:
    // SU2's RMS residual is the raw flux balance of each dual cell, not divided by its volume, so on
    // an external-flow mesh it is set by the largest cells at the far-field boundary. Measured on the
    // wing: 91 % of the squared omega residual sat in twelve nodes on the far-field box edges, 3 m
    // from the body, where omega is at its free-stream value — flat at 10^1.38 for hundreds of
    // iterations while the flow near the wing developed. (Before that, a fixed absolute target on
    // omega rejected a converged run whose omega had fallen four decades.) Whether the turbulence
    // model has settled near the body is what the forces and moments below measure.
    std::vector<std::string> residuals{"rms[P]","rms[U]","rms[V]","rms[W]"};
    for (const auto& key:residuals) {
        const int column=h.column(key);if(column<0)return fail("нет невязки "+key);
        double worst=-100,minDrop=INFINITY;
        for(std::size_t row=0;row<h.rows.size();++row)
            if(h.rows[row].size()<=static_cast<std::size_t>(column)||!std::isfinite(h.rows[row][column]))return fail("нет конечной невязки "+key);
        for(std::size_t i=0;i<representativeRows.size();++i){const auto row=representativeRows[i];worst=std::max(worst,h.rows[row][column]);if(isUnsteady(s))minDrop=std::min(minDrop,h.rows[firstRows[i]][column]-h.rows[row][column]);}
        out.residual=std::max(out.residual,worst);
        if (isUnsteady(s)) {
            // In dual-time stepping an equation is converged within a physical step when it either
            // reaches the absolute target or falls by at least 1.5 decades inside that step.
            if (worst>s.residualTarget && minDrop<1.5)
                out.problems.push_back("не сошлось за физический шаг (увеличьте внутренние итерации): "+key+" = "+brief(worst)+", минимальное падение "+brief(minDrop));
        } else if (worst>s.residualTarget) {
            out.problems.push_back("не достигнута сходимость: "+key+" = "+brief(worst)+" при цели "+brief(s.residualTarget));
        }
    }
    if (isTurbulent(s))
        for (const auto* key:{"rms[k]","rms[w]"}) {
            const int column=h.column(key);if(column<0)return fail(std::string("нет невязки ")+key);
            for(const auto& row:h.rows) if(row.size()<=static_cast<std::size_t>(column)||!std::isfinite(row[column])) return fail(std::string("нет конечной невязки ")+key);
        }
    std::map<std::string,double> coefficients;
    for (const auto* key:{"CFx","CFy","CFz","CMx","CMy","CMz"}) {
        const int c=h.column(key);
        if (c<0 || !std::isfinite(h.last(key))) return fail(std::string("нет коэффициента ")+key);
        double low=INFINITY,high=-INFINITY,sum=0,first=0,second=0;const auto half=representativeRows.size()/2;
        for (std::size_t i=0;i<representativeRows.size();++i) {
            const auto row=representativeRows[i];if (h.rows[row].size()<=static_cast<std::size_t>(c) || !std::isfinite(h.rows[row][c])) return fail("повреждена история коэффициентов");
            const double value=h.rows[row][c];low=std::min(low,value);high=std::max(high,value);sum+=value;(i<half?first:second)+=value;
        }
        const double mean=sum/representativeRows.size();coefficients[key]=isUnsteady(s)?mean:h.last(key);
        out.coefficientSpread=std::max(out.coefficientSpread,high-low);
        if(isUnsteady(s)) {
            first/=half;second/=(representativeRows.size()-half);
            if(std::abs(second-first)>s.coefficientAbsoluteTolerance+s.coefficientRelativeTolerance*std::abs(mean))
                out.problems.push_back(std::string("среднее по времени ещё дрейфует (увеличьте физическое время или окно усреднения): ")+key);
        } else if (high-low>s.coefficientAbsoluteTolerance+s.coefficientRelativeTolerance*std::abs(h.last(key)))
            out.problems.push_back(std::string("силы/моменты ещё меняются: ")+key);
    }
    const double a=alpha*pi/180,b=beta*pi/180;
    const Point3 f{coefficients["CFx"],coefficients["CFy"],coefficients["CFz"]};
    out.cd=dot(f,flowDirection(alpha,beta)); out.cl=dot(f,{-std::sin(a),0,std::cos(a)});
    out.cy=dot(f,{std::cos(a)*std::sin(b),std::cos(b),std::sin(a)*std::sin(b)});
    out.cm=coefficients["CMy"]; out.cRoll=coefficients["CMx"]*s.reference.chordM/s.reference.spanM;
    out.cYaw=coefficients["CMz"]*s.reference.chordM/s.reference.spanM;
    if (out.cd<0) out.problems.push_back(s.model=="euler"
        ? "Euler дал отрицательное численное сопротивление: поле можно просматривать, CD нельзя; уточните сетку или возьмите вязкую модель"
        : "отрицательное сопротивление: проверьте сетку, направление обдува и сходимость");
    // The near-wall mesh is measured from the solution, not promised by the settings.
    // y+ bands describe a turbulent boundary layer. Laminar flow has neither a viscous sublayer to
    // resolve nor a log layer to model, so its near-wall requirement is the layer thickness, checked
    // in the setup problems below.
    if (isTurbulent(s)) {
        WallTreatment treatment{};
        parseWallTreatment(s.wallTreatment,treatment);
        out.wall=assessWallResolution(surface,treatment);
        if (!out.wall.problem.empty()) {
            std::string problem=out.wall.problem;
            // The measured y+ is proportional to the first layer, so it says exactly how to fix the
            // mesh — and it beats any correlation, which on a frame with local accelerations can be
            // off by a factor of several.
            if (out.wall.measured && out.wall.median>0 && !s.layerHeightsM.empty()) {
                const double target=treatment==WallTreatment::Resolved ? 1.0 : 50.0;
                problem+="; по измеренному y+ первый слой должен быть "+brief(s.layerHeightsM.front()*target/out.wall.median)
                         +" м вместо "+brief(s.layerHeightsM.front())+" м";
            }
            out.problems.push_back(problem);
        }
    }
    // SU2 prints this when its wall-model Newton fails at a node — on a frame with sharp edges and
    // separated corners the log law does not hold there, and the model falls back to fixed values.
    if (run.log.find("wall coefficients (y+) did not converge")!=std::string::npos)
        out.problems.push_back("пристеночная модель не сошлась в части узлов: логарифмический закон там не выполняется; для такой геометрии нужен разрешённый пограничный слой");
    for (const auto& problem:aeroSetupProblems(s,out.wall.measured)) out.problems.push_back(problem);
    return Result<AeroSample>::ok(out);
}

Json aeroSampleJson(const AeroSample& s) {
    auto j=Json::makeObject();
    j.set("alphaDeg",num(s.alphaDeg)); j.set("betaDeg",num(s.betaDeg)); j.set("cl",num(s.cl)); j.set("cd",num(s.cd)); j.set("cm",num(s.cm));
    j.set("cy",num(s.cy)); j.set("cRoll",num(s.cRoll)); j.set("cYaw",num(s.cYaw));
    j.set("iterations",num(s.iterations)); j.set("residual",num(s.residual)); j.set("coefficientSpread",num(s.coefficientSpread));
    j.set("directory",str(s.directory));
    j.set("usable",Json::makeBool(s.usable()));
    auto problems=Json::makeArray(); for (const auto& problem:s.problems) problems.arrayItems.push_back(str(problem));
    j.set("problems",problems);
    if (s.wall.measured) {
        auto wall=Json::makeObject();
        wall.set("nodes",num(s.wall.nodes)); wall.set("median",num(s.wall.median)); wall.set("p95",num(s.wall.p95));
        wall.set("maximum",num(s.wall.maximum)); wall.set("minimum",num(s.wall.minimum));
        wall.set("shareBelow1",num(s.wall.shareBelow1)); wall.set("shareBuffer5to30",num(s.wall.shareBuffer));
        wall.set("shareLog30to300",num(s.wall.shareLog)); wall.set("shareAbove300",num(s.wall.shareAbove300));
        wall.set("valid",Json::makeBool(s.wall.valid));
        j.set("yPlus",wall);
    }
    return j;
}
Json aeroResultJson(const AeroJob& job,const std::vector<AeroSample>& samples,const std::string& version,const std::string& mesher,const std::string& error) {
    auto r=Json::makeObject(); r.set("schema",str("cadnext-aerodynamics-result/1")); r.set("testType",str("aerodynamics"));
    const bool complete=error.empty() && samples.size()==job.settings.alphaDeg.size()*job.settings.betaDeg.size();
    // "Complete" means every requested point was computed and its fields written. Usable means more:
    // every point also passed convergence, near-wall resolution and the model-against-Reynolds check.
    // Only usable runs export a table the simulator may fly with; a complete-but-flawed run keeps its
    // fields and says, point by point, what is wrong with it.
    const bool usable=complete && std::all_of(samples.begin(),samples.end(),[](const AeroSample& p){return p.usable();});
    r.set("outcome",str(complete?"warning":"error")); r.set("coefficientsUsable",Json::makeBool(usable)); r.set("solverID",str("cadnext-su2")); r.set("solverVersion",str(version));
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
        warnings.arrayItems.push_back(str(isUnsteady(job.settings)
            ? "Нестационарный несжимаемый URANS k-omega SST; коэффициенты усреднены по конечному временному окну. Рули и обдув винтов не рассчитаны."
            : "Стационарное несжимаемое течение, фиксированные Re; рули и обдув винтов не рассчитаны."));
        if (job.settings.model=="euler") warnings.arrayItems.push_back(str("Euler: нет трения и вязкого срыва. Только диагностика; таблица не допускается в физику."));
        if (job.settings.wallTreatment=="functions" && isTurbulent(job.settings))
            warnings.arrayItems.push_back(str("Пристеночные функции требуют SU2 с патчем CADNext/tools/su2-patches: в штатной сборке 8.5 многопоточный запуск с ними зависает."));
        if (isTurbulent(job.settings)) warnings.arrayItems.push_back(str(job.settings.transition=="lm"
            ? "Переход γ-Reθ (Langtry–Menter): пограничный слой начинается ламинарным; место перехода определяется интенсивностью турбулентности набегающего потока Tu = "+brief(job.settings.turbulenceIntensity*100)+" %. Сверка с экспериментом ERCOFTAC T3A/T3A− (cadnext_test_cfd_t3a): переход наступает раньше измеренного (T3A — на ~28 % по Re_x, T3A− — на ~9 %), трение ламинарного и предпереходного слоя завышено на 10–30 %; турбулентная часть — в пределах 6 %. Для сопротивления трения это ошибка в запас."
            : "Без модели перехода: пограничный слой турбулентный от передней кромки; при Re < 10^6 трение завышено."));
        if (isTurbulent(job.settings)) warnings.arrayItems.push_back(str("Невязки k и ω не служат критерием: их RMS задают крупные ячейки у дальней границы; установление турбулентной модели у тела проверено через стационарность сил и моментов."));
        if (isTurbulent(job.settings)) warnings.arrayItems.push_back(str(job.settings.wallTreatment=="functions"
            ? "Пристеночные функции: трение у стенки взято из логарифмического закона, а не рассчитано; в зонах торможения и отрыва это оценка. На пластине они занижают трение на ~5 % против канонического слоя (cadnext_test_cfd_turbulent_plate)."
            : "Пограничный слой разрешается сеткой; достаточность проверена по y+ рассчитанного поля."));
        else if (job.settings.model=="laminar") warnings.arrayItems.push_back(str("Ламинарная модель: переход к турбулентности не моделируется; проверьте число Рейнольдса."));
        if (!usable) warnings.arrayItems.push_back(str("Коэффициенты не пригодны для расчёта: причины перечислены по точкам. Поля можно просматривать."));
        if (job.settings.alphaDeg.size()==1) warnings.arrayItems.push_back(str("Одиночный угол атаки не задаёт полярную кривую для полёта."));
        if (job.settings.betaDeg.size()==1) warnings.arrayItems.push_back(str("Зависимость от скольжения не рассчитана; в полёте боковые производные берутся из профиля."));
    }
    r.set("warnings",warnings);
    auto failures=Json::makeArray();
    if (!complete) failures.arrayItems.push_back(str(error.empty()?"серия не завершена":error));
    for (const auto& sample:samples) {
        for (const auto& problem:sample.problems) {
            failures.arrayItems.push_back(str("α = "+brief(sample.alphaDeg)+"°, β = "+brief(sample.betaDeg)+"°: "+problem));
        }
    }
    r.set("failureReasons",failures);
    auto metrics=Json::makeObject(); auto metric=[&](const char* key,double value,const char* unit) { auto m=Json::makeObject(); m.set("value",num(value)); m.set("unit",str(unit)); metrics.set(key,m); };
    metric("completedPoints",static_cast<double>(samples.size()),"1"); metric("requestedPoints",job.settings.alphaDeg.size()*job.settings.betaDeg.size(),"1");
    metric("usablePoints",static_cast<double>(std::count_if(samples.begin(),samples.end(),[](const AeroSample& p){return p.usable();})),"1");
    metric("reynoldsChord",aeroReynolds(job.settings),"1");
    {
        double worstMedian=0,worstMaximum=0; bool measured=false;
        for (const auto& sample:samples) if (sample.wall.measured) { measured=true; worstMedian=std::max(worstMedian,sample.wall.median); worstMaximum=std::max(worstMaximum,sample.wall.maximum); }
        if (measured) { metric("wallYPlusMedian",worstMedian,"1"); metric("wallYPlusMaximum",worstMaximum,"1"); }
    }
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
    r.set("metrics",metrics); r.set("fieldRef",str("flow"));
    auto points=Json::makeArray(); for (const auto& sample:samples) points.arrayItems.push_back(aeroSampleJson(sample)); r.set("points",points);
    if (usable) {
        auto table=Json::makeObject(); table.set("schema",str("uavsim-aerodynamics/1"));
        table.set("frame",str("flight-body-rhu")); table.set("reference",*settings.member("reference"));
        table.set("speedMps",num(job.settings.speedMps)); table.set("densityKgM3",num(job.settings.densityKgM3)); table.set("viscosityPaS",num(job.settings.viscosityPaS));
        table.set("model",str(job.settings.model)); table.set("alphaDeg",array(job.settings.alphaDeg)); table.set("betaDeg",array(job.settings.betaDeg));
        table.set("points",points); r.set("aeroTable",table);
    }
    return r;
}
std::string aeroCapabilitiesJson() {
    return R"({"schema":"cadnext-aerodynamics-capabilities/1","adapterVersion":"1","solver":"SU2","models":["euler","laminar","sst","urans_sst"],"wallTreatments":["resolved","functions"],"transition":["none","lm"],"modes":["singlePoint","alphaSweep","betaSweep","alphaBetaSweep"],"steady":true,"unsteady":true,"compressible":false,"maxSpeedMps":100,"controlSurfaceSweep":false,"propwash":false,"gridUncertainty":false,"cancel":true,"fields":["pressure","velocity"],"geometry":"brep-ascii-metres"})";
}
} // namespace cadnext::cfd
