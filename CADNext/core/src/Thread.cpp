#include "cadnext/Thread.hpp"

#include <cmath>
#include <cstdio>
#include <limits>

namespace cadnext {

namespace {

constexpr double kInchMm = 25.4;

// "8", "1,25", "0,35": a size as a Russian drawing writes it.
std::string number(double value) {
    char text[32];
    std::snprintf(text, sizeof text, "%.4f", value);
    std::string s = text;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    for (char& c : s)
        if (c == '.') c = ',';
    return s;
}

std::vector<ThreadSize> metricCoarse() {
    // ISO 261 / ГОСТ 8724-2002, крупный шаг.
    const double table[][2] = {{1, 0.25},  {1.2, 0.25}, {1.4, 0.3}, {1.6, 0.35}, {1.8, 0.35}, {2, 0.4},   {2.2, 0.45},
                               {2.5, 0.45}, {3, 0.5},    {3.5, 0.6}, {4, 0.7},    {4.5, 0.75}, {5, 0.8},   {6, 1},
                               {7, 1},     {8, 1.25},   {10, 1.5},  {12, 1.75},  {14, 2},     {16, 2},    {18, 2.5},
                               {20, 2.5},  {22, 2.5},   {24, 3},    {27, 3},     {30, 3.5},   {33, 3.5},  {36, 4},
                               {39, 4},    {42, 4.5},   {45, 4.5},  {48, 5},     {52, 5},     {56, 5.5},  {60, 5.5},
                               {64, 6},    {68, 6}};
    std::vector<ThreadSize> sizes;
    for (const auto& row : table) sizes.push_back({"M" + number(row[0]), row[0], row[1]});
    return sizes;
}

std::vector<ThreadSize> metricFine() {
    // ISO 261 / ГОСТ 8724-2002, мелкие шаги, from the coarsest.
    struct Row {
        double d;
        std::vector<double> pitches;
    };
    const std::vector<Row> table{
        {1, {0.2}},          {1.2, {0.2}},         {1.4, {0.2}},         {1.6, {0.2}},         {1.8, {0.2}},
        {2, {0.25}},         {2.5, {0.35}},        {3, {0.35}},          {3.5, {0.35}},        {4, {0.5}},
        {5, {0.5}},          {6, {0.75}},          {8, {1, 0.75}},       {10, {1.25, 1, 0.75}}, {12, {1.5, 1.25, 1}},
        {14, {1.5, 1}},      {16, {1.5, 1}},       {18, {2, 1.5, 1}},    {20, {2, 1.5, 1}},    {22, {2, 1.5, 1}},
        {24, {2, 1.5, 1}},   {27, {2, 1.5, 1}},    {30, {3, 2, 1.5, 1}}, {33, {3, 2, 1.5}},    {36, {3, 2, 1.5}},
        {39, {3, 2, 1.5}},   {42, {4, 3, 2, 1.5}}, {45, {4, 3, 2, 1.5}}, {48, {4, 3, 2, 1.5}}, {52, {4, 3, 2, 1.5}},
        {56, {4, 3, 2, 1.5}}, {60, {4, 3, 2, 1.5}}, {64, {4, 3, 2, 1.5}}};
    std::vector<ThreadSize> sizes;
    for (const Row& row : table)
        for (const double pitch : row.pitches) sizes.push_back({"M" + number(row.d) + "×" + number(pitch), row.d, pitch});
    return sizes;
}

struct InchRow {
    const char* size;
    double diameterIn, threadsPerInch;
};

std::vector<ThreadSize> unified(const std::vector<InchRow>& table, const char* series) {
    std::vector<ThreadSize> sizes;
    for (const InchRow& row : table)
        sizes.push_back({std::string(row.size) + "-" + number(row.threadsPerInch) + " " + series, row.diameterIn * kInchMm,
                         kInchMm / row.threadsPerInch});
    return sizes;
}

std::vector<ThreadSize> unc() {
    // ASME B1.1, UNC.
    return unified({{"#1", 0.073, 64},   {"#2", 0.086, 56},      {"#3", 0.099, 48},   {"#4", 0.112, 40},     {"#5", 0.125, 40},
                    {"#6", 0.138, 32},   {"#8", 0.164, 32},      {"#10", 0.190, 24},  {"#12", 0.216, 24},    {"1/4", 0.25, 20},
                    {"5/16", 0.3125, 18}, {"3/8", 0.375, 16},    {"7/16", 0.4375, 14}, {"1/2", 0.5, 13},      {"9/16", 0.5625, 12},
                    {"5/8", 0.625, 11},  {"3/4", 0.75, 10},      {"7/8", 0.875, 9},   {"1", 1.0, 8},         {"1 1/8", 1.125, 7},
                    {"1 1/4", 1.25, 7},  {"1 3/8", 1.375, 6},    {"1 1/2", 1.5, 6},   {"1 3/4", 1.75, 5},    {"2", 2.0, 4.5},
                    {"2 1/4", 2.25, 4.5}, {"2 1/2", 2.5, 4},     {"2 3/4", 2.75, 4},  {"3", 3.0, 4},         {"3 1/4", 3.25, 4},
                    {"3 1/2", 3.5, 4},   {"3 3/4", 3.75, 4},     {"4", 4.0, 4}},
                   "UNC");
}

std::vector<ThreadSize> unf() {
    // ASME B1.1, UNF.
    return unified({{"#0", 0.060, 80},   {"#1", 0.073, 72},     {"#2", 0.086, 64},    {"#3", 0.099, 56},    {"#4", 0.112, 48},
                    {"#5", 0.125, 44},   {"#6", 0.138, 40},     {"#8", 0.164, 36},    {"#10", 0.190, 32},   {"#12", 0.216, 28},
                    {"1/4", 0.25, 28},   {"5/16", 0.3125, 24},  {"3/8", 0.375, 24},   {"7/16", 0.4375, 20}, {"1/2", 0.5, 20},
                    {"9/16", 0.5625, 18}, {"5/8", 0.625, 18},   {"3/4", 0.75, 16},    {"7/8", 0.875, 14},   {"1", 1.0, 12},
                    {"1 1/8", 1.125, 12}, {"1 1/4", 1.25, 12},  {"1 3/8", 1.375, 12}, {"1 1/2", 1.5, 12}},
                   "UNF");
}

std::vector<ThreadSize> pipeG() {
    // ISO 228-1 / ГОСТ 6357-81: size, threads per inch, major diameter (mm).
    const struct {
        const char* size;
        double threadsPerInch, major;
    } table[] = {{"1/16", 28, 7.723},    {"1/8", 28, 9.728},    {"1/4", 19, 13.157},   {"3/8", 19, 16.662},  {"1/2", 14, 20.955},
                 {"5/8", 14, 22.911},    {"3/4", 14, 26.441},   {"7/8", 14, 30.201},   {"1", 11, 33.249},    {"1 1/8", 11, 37.897},
                 {"1 1/4", 11, 41.910},  {"1 1/2", 11, 47.803}, {"1 3/4", 11, 53.746}, {"2", 11, 59.614},    {"2 1/4", 11, 65.710},
                 {"2 1/2", 11, 75.184},  {"2 3/4", 11, 81.534}, {"3", 11, 87.884},     {"3 1/2", 11, 100.330}, {"4", 11, 113.030},
                 {"4 1/2", 11, 125.730}, {"5", 11, 138.430},    {"5 1/2", 11, 151.130}, {"6", 11, 163.830}};
    std::vector<ThreadSize> sizes;
    for (const auto& row : table) sizes.push_back({std::string("G") + row.size, row.major, kInchMm / row.threadsPerInch});
    return sizes;
}

std::vector<ThreadSize> pipeR() {
    // ISO 7-1 / ГОСТ 6211-81: size, threads per inch, major diameter at the gauge plane (mm), gauge length (mm).
    const struct {
        const char* size;
        double threadsPerInch, major, gauge;
    } table[] = {{"1/16", 28, 7.723, 4.0},   {"1/8", 28, 9.728, 4.0},    {"1/4", 19, 13.157, 6.0},   {"3/8", 19, 16.662, 6.4},
                 {"1/2", 14, 20.955, 8.2},   {"3/4", 14, 26.441, 9.5},   {"1", 11, 33.249, 10.4},    {"1 1/4", 11, 41.910, 12.7},
                 {"1 1/2", 11, 47.803, 12.7}, {"2", 11, 59.614, 15.9},   {"2 1/2", 11, 75.184, 17.5}, {"3", 11, 87.884, 20.6},
                 {"4", 11, 113.030, 25.4},   {"5", 11, 138.430, 28.6},   {"6", 11, 163.830, 28.6}};
    std::vector<ThreadSize> sizes;
    for (const auto& row : table) sizes.push_back({std::string("R") + row.size, row.major, kInchMm / row.threadsPerInch, row.gauge});
    return sizes;
}

std::vector<ThreadSize> npt() {
    // ASME B1.20.1: size, pipe OD D (in), threads per inch, L1 (in). E0 = D - (0.05D + 1.1)p at the small
    // end; the gauge (hand-tight) plane L1 on, E1 = E0 + L1/16; the major there E1 + 0.8p.
    const struct {
        const char* size;
        double outside, threadsPerInch, handTight;
    } table[] = {{"1/16", 0.3125, 27, 0.160}, {"1/8", 0.405, 27, 0.1615},   {"1/4", 0.540, 18, 0.2278},  {"3/8", 0.675, 18, 0.240},
                 {"1/2", 0.840, 14, 0.320},   {"3/4", 1.050, 14, 0.339},    {"1", 1.315, 11.5, 0.400},   {"1 1/4", 1.660, 11.5, 0.420},
                 {"1 1/2", 1.900, 11.5, 0.420}, {"2", 2.375, 11.5, 0.436},  {"2 1/2", 2.875, 8, 0.682},  {"3", 3.500, 8, 0.766},
                 {"4", 4.500, 8, 0.844}};
    std::vector<ThreadSize> sizes;
    for (const auto& row : table) {
        const double p = 1.0 / row.threadsPerInch, e0 = row.outside - (0.05 * row.outside + 1.1) * p;
        const double e1 = e0 + row.handTight / 16;
        sizes.push_back({std::string(row.size) + "-" + number(row.threadsPerInch) + " NPT", (e1 + 0.8 * p) * kInchMm, p * kInchMm,
                         row.handTight * kInchMm});
    }
    return sizes;
}

} // namespace

ThreadForm threadForm(ThreadStandard standard) {
    switch (standard) {
    case ThreadStandard::PipeG:
    case ThreadStandard::PipeR: return ThreadForm::Whitworth55;
    case ThreadStandard::Npt: return ThreadForm::Npt60;
    default: return ThreadForm::Metric60;
    }
}

bool threadIsTaper(ThreadStandard standard) {
    return standard == ThreadStandard::PipeR || standard == ThreadStandard::Npt;
}

double threadTaper(ThreadStandard standard) { return threadIsTaper(standard) ? 1.0 / 16 : 0.0; }

const std::vector<ThreadSize>& threadSizes(ThreadStandard standard) {
    static const std::vector<ThreadSize> coarse = metricCoarse(), fine = metricFine(), uncSizes = unc(), unfSizes = unf(),
                                         g = pipeG(), r = pipeR(), nptSizes = npt(), none;
    switch (standard) {
    case ThreadStandard::MetricCoarse: return coarse;
    case ThreadStandard::MetricFine: return fine;
    case ThreadStandard::Unc: return uncSizes;
    case ThreadStandard::Unf: return unfSizes;
    case ThreadStandard::PipeG: return g;
    case ThreadStandard::PipeR: return r;
    case ThreadStandard::Npt: return nptSizes;
    case ThreadStandard::Custom: return none;
    }
    return none;
}

double threadDepthMm(ThreadForm form, double pitchMm) {
    switch (form) {
    case ThreadForm::Metric60: return 5.0 / 8.0 * std::sqrt(3.0) / 2.0 * pitchMm;
    case ThreadForm::Whitworth55: return 0.640327 * pitchMm;
    case ThreadForm::Npt60: return 0.8 * pitchMm;
    }
    return 0.0;
}

double threadMinorDiameterMm(ThreadForm form, double majorDiameterMm, double pitchMm) {
    return majorDiameterMm - 2.0 * threadDepthMm(form, pitchMm);
}

int nearestThreadSize(ThreadStandard standard, double diameterMm, bool internal) {
    const std::vector<ThreadSize>& sizes = threadSizes(standard);
    int best = -1;
    double bestGap = std::numeric_limits<double>::infinity();
    for (int i = 0; i < int(sizes.size()); ++i) {
        const ThreadSize& size = sizes[i];
        const double surface =
            internal ? threadMinorDiameterMm(threadForm(standard), size.majorDiameterMm, size.pitchMm) : size.majorDiameterMm;
        const double gap = std::fabs(surface - diameterMm);
        if (gap < bestGap) bestGap = gap, best = i;
    }
    return best;
}

const char* threadStandardTitle(ThreadStandard standard) {
    switch (standard) {
    case ThreadStandard::MetricCoarse: return "Метрическая, крупный шаг (ISO 261, ГОСТ 8724)";
    case ThreadStandard::MetricFine: return "Метрическая, мелкий шаг (ISO 261, ГОСТ 8724)";
    case ThreadStandard::Unc: return "Дюймовая UNC (ASME B1.1)";
    case ThreadStandard::Unf: return "Дюймовая UNF (ASME B1.1)";
    case ThreadStandard::PipeG: return "Трубная цилиндрическая G (ISO 228-1, ГОСТ 6357)";
    case ThreadStandard::PipeR: return "Трубная коническая R / Rc (ISO 7-1, ГОСТ 6211)";
    case ThreadStandard::Npt: return "Трубная коническая NPT (ASME B1.20.1)";
    case ThreadStandard::Custom: return "Своя: метрический профиль, любые диаметр и шаг";
    }
    return "";
}

const char* threadStandardKey(ThreadStandard standard) {
    switch (standard) {
    case ThreadStandard::MetricCoarse: return "MetricCoarse";
    case ThreadStandard::MetricFine: return "MetricFine";
    case ThreadStandard::Unc: return "UNC";
    case ThreadStandard::Unf: return "UNF";
    case ThreadStandard::PipeG: return "G";
    case ThreadStandard::PipeR: return "R";
    case ThreadStandard::Npt: return "NPT";
    case ThreadStandard::Custom: return "Custom";
    }
    return "MetricCoarse";
}

ThreadStandard threadStandardFromKey(const std::string& key) {
    for (const ThreadStandard standard :
         {ThreadStandard::MetricCoarse, ThreadStandard::MetricFine, ThreadStandard::Unc, ThreadStandard::Unf,
          ThreadStandard::PipeG, ThreadStandard::PipeR, ThreadStandard::Npt, ThreadStandard::Custom})
        if (key == threadStandardKey(standard)) return standard;
    return ThreadStandard::MetricCoarse;
}

bool threadParametersValid(const ThreadParameters& p) {
    if (p.targetBodyId.empty()) return false;
    if (!std::isfinite(p.majorDiameterMm) || !std::isfinite(p.pitchMm) || !std::isfinite(p.lengthMm)) return false;
    const ThreadSurface& s = p.surface;
    const double axis = std::sqrt(s.axisDirection.x * s.axisDirection.x + s.axisDirection.y * s.axisDirection.y +
                                  s.axisDirection.z * s.axisDirection.z);
    if (!(s.radius > 0.0) || !(axis > 0.0) || !(s.length() > 0.0)) return false;
    return p.pitchMm > 0.0 && p.majorDiameterMm > 2.0 * p.pitchMm && p.lengthMm > p.pitchMm;
}

std::string threadMarking(const ThreadParameters& p) {
    std::string base = p.designation;
    if (p.standard == ThreadStandard::Custom || base.empty()) base = "M" + number(p.majorDiameterMm) + "×" + number(p.pitchMm);
    // ISO 7-1: R external, Rc internal.
    if (p.standard == ThreadStandard::PipeR && p.internal && base.rfind("R", 0) == 0) base = "Rc" + base.substr(1);
    if (p.rightHanded) return base;
    // ГОСТ 2.311 / ISO 965: LH after the designation; the unified and NPT designations take it hyphenated.
    const bool hyphen = p.standard == ThreadStandard::Unc || p.standard == ThreadStandard::Unf || p.standard == ThreadStandard::Npt;
    return base + (hyphen ? "-LH" : "LH");
}

} // namespace cadnext
