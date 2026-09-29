#include "cadnext/gui/NativeAcisSat.hpp"

#include "cadnext/kernel/OcctKernel.hpp"

#include <QFile>
#include <QFileInfo>
#include <QObject>
#include <QRegularExpression>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <unordered_map>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBuilderAPI_Transform.hxx>
#include <GeomAPI_Interpolate.hxx>
#include <GeomAPI_PointsToBSpline.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_BSplineSurface.hxx>
#include <Geom_Circle.hxx>
#include <Geom_ConicalSurface.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_Ellipse.hxx>
#include <Geom_Line.hxx>
#include <Geom_Plane.hxx>
#include <Geom_SphericalSurface.hxx>
#include <Geom_SurfaceOfLinearExtrusion.hxx>
#include <Geom_ToroidalSurface.hxx>
#include <GeomLProp_SLProps.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <TColgp_Array2OfPnt.hxx>
#include <TColgp_HArray1OfPnt.hxx>
#include <TColStd_HArray1OfReal.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array2OfReal.hxx>
#include <Standard_Failure.hxx>
#include <gp_Trsf.hxx>
#endif

namespace cadnext::gui {

namespace {

// --- Tokens and records ----------------------------------------------------------------------------

struct Token {
    enum class Kind { Pointer, Number, Word, String, Open, Close } kind = Kind::Word;
    double value = 0.0;    // Number; Pointer: the index (-1 null)
    std::string text;      // Word, String
};

struct Record {
    long long index = -1;
    std::string type;
    std::vector<Token> data; // after the type identifier, up to the terminator
};

struct Surface;
struct Curve;

bool numberToken(const std::string& text, double& value) {
    if (text.empty()) return false;
    char* end = nullptr;
    value = std::strtod(text.c_str(), &end);
    return end && *end == '\0' && std::isfinite(value);
}

struct SatFile {
    int version = 0;
    double millimetresPerUnit = 0.0;
    double resabs = 1e-6; // how near points must be to be one (model units): ACIS's default, or the header's
    std::vector<Record> records;                     // in file order
    std::unordered_map<long long, std::size_t> byIndex;
    // Subtype definitions in the order the file defines them ("ref n" names the n-th): the record and
    // the position of its '{'.
    std::vector<std::pair<std::size_t, std::size_t>> subtypes;
    // Tokens before a class's own data: the attribute pointer, then ids in later versions — and for
    // geometry (points, curves, surfaces), which ACIS 5.0 use-counts, one more there than for topology.
    int header = 1;         // topology
    int geometryHeader = 1; // points, curves, surfaces
    // SAB (binary ACIS, "ACIS BinaryFile" / "ASM BinaryFile4"): its logicals carry no words, only two
    // tags — read here as "T" (reversed, double, and a finite interval end, its value after it) and "I"
    // (forward, single, an infinite end), as the samples' faces and intervals show.
    bool binary = false;
    // Rolling-ball blends by where their definition's '{' is (the tokens and the position after it):
    // faces and edges that name one blend, directly or by "ref", share one definition.
    mutable std::map<std::pair<const void*, std::size_t>, std::shared_ptr<kernel::RollingBallBlend>> blends;
    mutable std::map<std::pair<const void*, std::size_t>, std::shared_ptr<Surface>> procedures;
    mutable std::map<std::pair<const void*, std::size_t>, std::shared_ptr<Curve>> curves;

    const Record* record(long long index) const {
        const auto it = byIndex.find(index);
        return it == byIndex.end() ? nullptr : &records[it->second];
    }
};

bool tokenize(const QByteArray& bytes, SatFile& file, QString& error) {
    const std::string text(bytes.constData(), std::size_t(bytes.size()));
    std::size_t at = 0;
    const auto line = [&]() {
        const std::size_t end = text.find('\n', at);
        std::string out = text.substr(at, end == std::string::npos ? std::string::npos : end - at);
        at = end == std::string::npos ? text.size() : end + 1;
        return out;
    };
    // Header: "version records entities flags"; from 4.0 on two more lines, the product and the units.
    {
        const std::string first = line();
        int records = 0, entities = 0, flags = 0;
        if (std::sscanf(first.c_str(), "%d %d %d %d", &file.version, &records, &entities, &flags) < 1 || file.version < 100) {
            error = QObject::tr("Это не файл ACIS SAT: нет заголовка с версией.");
            return false;
        }
        std::size_t peek = at;
        while (peek < text.size() && std::isspace(static_cast<unsigned char>(text[peek]))) ++peek;
        const std::string next = text.substr(peek, 40);
        const bool record = !next.empty() && (next[0] == '-' || std::isalpha(static_cast<unsigned char>(next[0])));
        if (!record) {
            line(); // product, ACIS version, date
            const std::string units = line();
            double millimetres = 0.0, resabs = 0.0;
            const int read = std::sscanf(units.c_str(), "%lf %lf", &millimetres, &resabs);
            if (read >= 1 && millimetres > 0.0) file.millimetresPerUnit = millimetres;
            if (read >= 2 && std::isfinite(resabs) && resabs > 0.0) file.resabs = resabs;
        }
    }

    Record current;
    bool inRecord = false;
    bool expectType = false;
    const auto finish = [&]() {
        if (!inRecord) return;
        if (current.index < 0) current.index = static_cast<long long>(file.records.size());
        file.byIndex[current.index] = file.records.size();
        file.records.push_back(std::move(current));
        current = {};
        inRecord = false;
    };
    while (at < text.size()) {
        const char c = text[at];
        if (std::isspace(static_cast<unsigned char>(c))) {
            ++at;
            continue;
        }
        if (!inRecord) {
            // A record: an optional sequence number "-N", then the type identifier.
            std::size_t end = at;
            while (end < text.size() && !std::isspace(static_cast<unsigned char>(text[end]))) ++end;
            const std::string word = text.substr(at, end - at);
            at = end;
            if (word == "End-of-ACIS-data" || word.rfind("Begin-of-ACIS-History", 0) == 0) break;
            double value = 0;
            if (!expectType && word.size() > 1 && word[0] == '-' && numberToken(word, value)) {
                current.index = static_cast<long long>(-value);
                expectType = true;
                continue;
            }
            current.type = word;
            inRecord = true;
            expectType = false;
            continue;
        }
        if (c == '#') {
            ++at;
            finish();
            continue;
        }
        if (c == '{' || c == '}') {
            current.data.push_back({c == '{' ? Token::Kind::Open : Token::Kind::Close});
            ++at;
            continue;
        }
        if (c == '@') {
            // "@n text": a string of n bytes after one space.
            std::size_t end = at + 1;
            while (end < text.size() && std::isdigit(static_cast<unsigned char>(text[end]))) ++end;
            const std::size_t length = std::size_t(std::strtoul(text.substr(at + 1, end - at - 1).c_str(), nullptr, 10));
            const std::size_t begin = std::min(text.size(), end + 1);
            current.data.push_back({Token::Kind::String, 0.0, text.substr(begin, length)});
            at = std::min(text.size(), begin + length);
            continue;
        }
        std::size_t end = at;
        while (end < text.size() && !std::isspace(static_cast<unsigned char>(text[end])) && text[end] != '#' &&
               text[end] != '{' && text[end] != '}')
            ++end;
        const std::string word = text.substr(at, end - at);
        at = end;
        Token token;
        double value = 0;
        if (word.size() > 1 && word[0] == '$' && numberToken(word.substr(1), value)) {
            token.kind = Token::Kind::Pointer;
            token.value = value;
        } else if (numberToken(word, value)) {
            token.kind = Token::Kind::Number;
            token.value = value;
        } else {
            token.kind = Token::Kind::Word;
            token.text = word;
        }
        current.data.push_back(std::move(token));
    }
    finish();
    if (file.records.empty()) {
        error = QObject::tr("В файле ACIS нет записей.");
        return false;
    }
    // Subtype definitions, numbered in the order the file writes them, nested ones included.
    for (std::size_t r = 0; r < file.records.size(); ++r) {
        const auto& data = file.records[r].data;
        for (std::size_t i = 0; i + 1 < data.size(); ++i)
            if (data[i].kind == Token::Kind::Open && !(data[i + 1].kind == Token::Kind::Word && data[i + 1].text == "ref"))
                file.subtypes.push_back({r, i});
    }
    // ENTITY's own fields: the attribute pointer; from 7.0 an id; later still more. Curves and surfaces
    // carry one more in 5.0 (their use count, before their data; a point's comes after its coordinates).
    // A vertex is those fields, an edge pointer and a point pointer (the last one); a straight line is
    // them, six reals and its interval (I, or F and a value, twice; from 1.06): their records say how many.
    std::optional<int> geometry, topology;
    const auto intervalFrom = [](const std::vector<Token>& data, std::size_t at) {
        std::size_t ends = 0;
        while (at < data.size()) {
            if (data[at].kind == Token::Kind::Word && data[at].text == "I") {
                ++at;
            } else if (data[at].kind == Token::Kind::Word && data[at].text == "F" && at + 1 < data.size() &&
                       data[at + 1].kind == Token::Kind::Number) {
                at += 2;
            } else {
                return false;
            }
            ++ends;
        }
        return ends == 0 || ends == 2;
    };
    for (const Record& record : file.records) {
        if (record.type == "straight-curve" && !geometry) {
            const auto& d = record.data;
            for (std::size_t w = 1; w + 6 <= d.size() && !geometry; ++w) {
                bool numbers = true;
                for (std::size_t i = w; i < w + 6; ++i) numbers = numbers && d[i].kind == Token::Kind::Number;
                if (numbers && intervalFrom(d, w + 6)) geometry = int(w);
            }
        } else if (record.type == "vertex") {
            int last = -1;
            for (int i = 0; i < int(record.data.size()); ++i)
                if (record.data[std::size_t(i)].kind == Token::Kind::Pointer) last = i;
            const int width = last - 1;
            if (width < 1 || (topology && *topology != width)) {
                error = QObject::tr("Записи вершин ACIS разной длины — раскладка версии %1 не распознана.").arg(file.version);
                return false;
            }
            topology = width;
        }
    }
    // A file without straight lines: an ellipse's ten reals and interval tell the same, else a
    // procedural curve's or surface's direction logical followed by its definition's '{'.
    for (const Record& record : file.records) {
        if (geometry) break;
        const auto& d = record.data;
        if (record.type == "ellipse-curve") {
            for (std::size_t w = 1; w + 10 <= d.size() && !geometry; ++w) {
                bool numbers = true;
                for (std::size_t i = w; i < w + 10; ++i) numbers = numbers && d[i].kind == Token::Kind::Number;
                if (numbers && intervalFrom(d, w + 10)) geometry = int(w);
            }
        } else if (record.type == "spline-surface" || record.type == "intcurve-curve") {
            for (std::size_t w = 1; w + 1 < d.size() && !geometry; ++w)
                if (d[w].kind == Token::Kind::Word && d[w + 1].kind == Token::Kind::Open) geometry = int(w);
        }
    }
    // A whole sphere or torus has neither vertices nor straight curves. A BODY containing
    // exactly its three class pointers still distinguishes the two ENTITY layouts.
    if (!topology) for (const Record& record : file.records) {
        if (record.type != "body" || record.data.size() < 4 || record.data.size() > 6) continue;
        const auto& data = record.data;
        if (data[0].kind != Token::Kind::Pointer) continue;
        bool pointers = true;
        for (std::size_t i = data.size() - 3; i < data.size(); ++i)
            pointers = pointers && data[i].kind == Token::Kind::Pointer;
        if (pointers) { topology = int(data.size() - 3); break; }
    }
    file.header = topology.value_or(file.version >= 700 ? 2 : 1);
    file.geometryHeader = geometry.value_or(file.header);
    return true;
}

// --- Reading fields --------------------------------------------------------------------------------

struct Cursor {
    const SatFile* file = nullptr;
    const std::vector<Token>* tokens = nullptr;
    std::size_t at = 0;
    bool ok = true;

    const Token* peek(std::size_t ahead = 0) const {
        return tokens && at + ahead < tokens->size() ? &(*tokens)[at + ahead] : nullptr;
    }
    bool is(Token::Kind kind, std::size_t ahead = 0) const {
        const Token* t = peek(ahead);
        return t && t->kind == kind;
    }
    bool isWord(const char* text, std::size_t ahead = 0) const {
        const Token* t = peek(ahead);
        return t && t->kind == Token::Kind::Word && t->text == text;
    }
    long long pointer() {
        if (!is(Token::Kind::Pointer)) return ok = false, -1;
        return static_cast<long long>((*tokens)[at++].value);
    }
    double number() {
        if (!is(Token::Kind::Number)) return ok = false, 0.0;
        return (*tokens)[at++].value;
    }
    std::string word() {
        if (!is(Token::Kind::Word)) return ok = false, std::string();
        return (*tokens)[at++].text;
    }
    // A logical: 0/1 in early files, a word later (forward/reversed, forward_v, single/double, F/T…).
    bool logical() {
        const Token* t = peek();
        if (!t) return ok = false, false;
        ++at;
        if (t->kind == Token::Kind::Number) return t->value != 0.0;
        if (t->kind != Token::Kind::Word) return ok = false, false;
        static const char* trueWords[] = {"reversed", "reversed_v", "reverse_v", "double", "in", "T", "TRUE", "true"};
        for (const char* w : trueWords)
            if (t->text == w) return true;
        return false;
    }
    bool isLogical(std::size_t ahead = 0) const {
        if (file && file->binary) return isWord("T", ahead) || isWord("I", ahead);
        const Token* t = peek(ahead);
        if (!t || t->kind != Token::Kind::Word) return false;
        static const char* words[] = {"forward", "reversed", "forward_v", "reversed_v", "reverse_v", "F", "T"};
        for (const char* w : words)
            if (t->text == w) return true;
        return false;
    }
    // An interval end: I (infinite), F then a value, or a value.
    void intervalEnd() {
        if (file && file->binary && isWord("T") && is(Token::Kind::Number, 1)) return void(at += 2);
        if (isWord("I")) {
            ++at;
        } else if (isWord("F") && is(Token::Kind::Number, 1)) {
            at += 2;
        } else {
            number();
        }
    }
    bool atIntervalEnd() const {
        if (file && file->binary && isWord("T") && is(Token::Kind::Number, 1)) return true;
        return isWord("I") || (isWord("F") && is(Token::Kind::Number, 1)) || is(Token::Kind::Number);
    }
    Vector3 triple() {
        const double x = number(), y = number(), z = number();
        return {x, y, z};
    }
    // Past the '}' closing the subtype whose '{' was just read.
    void closeSubtype() {
        int depth = 1;
        while (ok && depth > 0) {
            const Token* t = peek();
            if (!t) return void(ok = false);
            ++at;
            if (t->kind == Token::Kind::Open) ++depth;
            if (t->kind == Token::Kind::Close) --depth;
        }
    }
};

bool geometryRecord(const std::string& type) {
    const auto endsWith = [&](const char* suffix) {
        const std::size_t n = std::strlen(suffix);
        return type.size() >= n && type.compare(type.size() - n, n, suffix) == 0;
    };
    return type == "pcurve" || endsWith("-surface") || endsWith("-curve");
}

Cursor recordData(const SatFile& file, const Record& record) {
    Cursor cursor{&file, &record.data, 0, true};
    const int width = geometryRecord(record.type) ? file.geometryHeader : file.header;
    for (int i = 0; i < width; ++i) {
        if (!cursor.peek()) return cursor.ok = false, cursor;
        ++cursor.at;
    }
    return cursor;
}

// --- Geometry --------------------------------------------------------------------------------------

struct Placement {
    double scale = 1e-3; // model units to metres
    std::array<double, 9> rows{1, 0, 0, 0, 1, 0, 0, 0, 1}; // p' = (p · A) · s + t, ACIS's row vectors
    Vector3 translation{0, 0, 0};
    double factor = 1.0;

    Vector3 point(const Vector3& p) const {
        const Vector3 q = linear(p);
        return {(q.x * factor + translation.x) * scale, (q.y * factor + translation.y) * scale,
                (q.z * factor + translation.z) * scale};
    }
    Vector3 linear(const Vector3& v) const {
        return {v.x * rows[0] + v.y * rows[3] + v.z * rows[6], v.x * rows[1] + v.y * rows[4] + v.z * rows[7],
                v.x * rows[2] + v.y * rows[5] + v.z * rows[8]};
    }
    Vector3 direction(const Vector3& v) const {
        const Vector3 q = linear(v);
        const double n = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
        return n > 0 ? Vector3{q.x / n, q.y / n, q.z / n} : q;
    }
    double length(double l) const { return l * factor * scale; }
};

double norm(const Vector3& v) { return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }

Vector3 sum(const Vector3& a, const Vector3& b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
Vector3 subtract(const Vector3& a, const Vector3& b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
Vector3 scaled(const Vector3& v, double s) { return {v.x*s, v.y*s, v.z*s}; }
double dot(const Vector3& a, const Vector3& b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
Vector3 cross(const Vector3& a, const Vector3& b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
Vector3 unit(const Vector3& v) { const double n=norm(v); return n>1e-300?scaled(v,1.0/n):Vector3{}; }

using ScalarFunction = std::function<double(double)>;
using CurveFunction = std::function<Vector3(double)>;
using SurfaceFunction = std::function<Vector3(double, double)>;

// The scalar/vector laws used by the sampled ACIS sweeps: arithmetic, X, SIN/COS and DOMAIN.
// Parsed as expressions, never executed as code. Other laws are refused with their text.
class LawParser {
public:
    explicit LawParser(std::string text) : text_(std::move(text)) {}
    ScalarFunction scalar() {
        auto a=product();
        while (ok && (peek()=='+' || peek()=='-')) {
            const char op=text_[at_++]; auto b=product();
            a=[a,b,op](double x){return op=='+'?a(x)+b(x):a(x)-b(x);};
        }
        return a;
    }
    CurveFunction vector() {
        const bool domain=word("DOMAIN"); if (domain && !take('(')) return {};
        if (!word("VEC") || !take('(')) return ok=false, CurveFunction{};
        const auto x=scalar(); if (!take(',')) return {};
        const auto y=scalar(); if (!take(',')) return {};
        const auto z=scalar(); if (!take(')')) return {};
        if (domain) { if (!take(',')) return {}; scalar(); if (!take(',')) return {}; scalar(); if (!take(')')) return {}; }
        return [x,y,z](double t){return Vector3{x(t),y(t),z(t)};};
    }
    bool complete() { return ok && peek()=='\0'; }
    bool ok=true;
private:
    std::string text_; std::size_t at_=0; int depth_=0;
    char peek() { while (at_<text_.size() && std::isspace(static_cast<unsigned char>(text_[at_]))) ++at_; return at_<text_.size()?text_[at_]:'\0'; }
    bool take(char c) { if (peek()!=c) return ok=false; ++at_; return true; }
    bool word(const char* w) { peek(); const std::size_t n=std::strlen(w); if (text_.compare(at_,n,w)!=0) return false; at_+=n; return true; }
    ScalarFunction product() {
        auto a=primary();
        while (ok && (peek()=='*' || peek()=='/')) {
            const char op=text_[at_++]; auto b=primary(); a=[a,b,op](double x){return op=='*'?a(x)*b(x):a(x)/b(x);};
        }
        return a;
    }
    ScalarFunction primary() {
        if (++depth_>64) { ok=false; --depth_; return [](double){return 0.0;}; }
        const auto done=[&](ScalarFunction f){--depth_;return f;};
        const char c=peek();
        if (c=='+' || c=='-') { ++at_; auto f=primary(); return done([f,c](double x){return c=='-'?-f(x):f(x);}); }
        if (c=='(') { ++at_; auto f=scalar(); take(')'); return done(f); }
        if (word("SIN")) { take('('); auto f=scalar(); take(')'); return done([f](double x){return std::sin(f(x));}); }
        if (word("COS")) { take('('); auto f=scalar(); take(')'); return done([f](double x){return std::cos(f(x));}); }
        if (word("X")) return done([](double x){return x;});
        char* end=nullptr; const double value=std::strtod(text_.c_str()+at_,&end);
        if (end==text_.c_str()+at_ || !std::isfinite(value)) {ok=false;return done([](double){return 0.0;});}
        at_=std::size_t(end-text_.c_str()); return done([value](double){return value;});
    }
};

bool vectorLaw(Cursor& c, CurveFunction& function, QString& why) {
    const int length=int(c.number()); const std::string text=c.word();
    if (!c.ok || length<=0 || length>4096 || int(text.size())!=length)
        return why=QObject::tr("длина векторного закона ACIS"),false;
    LawParser parser(text); function=parser.vector();
    if (!function || !parser.complete()) return why=QObject::tr("векторный закон ACIS «%1»").arg(QString::fromStdString(text)),false;
    return true;
}

bool scalarLaw(Cursor& c, ScalarFunction& function, QString& why) {
    const int length=int(c.number());
    if (!c.ok || length<=0 || length>4096) return why=QObject::tr("длина скалярного закона ACIS"),false;
    if (c.is(Token::Kind::Number)) { const double v=c.number(); function=[v](double){return v;}; return c.ok; }
    const std::string text=c.word(); LawParser parser(text); function=parser.scalar();
    if (!c.ok || int(text.size())!=length || !parser.complete()) return why=QObject::tr("скалярный закон ACIS «%1»").arg(QString::fromStdString(text)),false;
    return true;
}

// ACIS B-splines keep degree-fold end knots (the end knots OCCT adds are implied); a "periodic" one is
// written clamped all the same, its first and last poles equal (all such curves in the samples).
bool bs3Curve(Cursor& c, const Placement& place, kernel::BSplineCurveDefinition& curve, QString& why) {
    if (c.isWord("full") || c.isWord("summary")) c.word();
    const std::string type = c.word();
    if (type != "nurbs" && type != "nubs") {
        why = QObject::tr("B-сплайн кривая ACIS «%1»").arg(QString::fromStdString(type));
        return false;
    }
    const bool rational = type == "nurbs";
    curve.degree = int(c.number());
    c.word(); // open, closed, periodic
    const int count = int(c.number());
    if (!c.ok || curve.degree < 1 || count < 2 || count > 100000) return why = QObject::tr("узлы B-сплайн кривой ACIS"), false;
    int total = 0;
    for (int i = 0; i < count; ++i) {
        curve.knots.push_back(c.number());
        curve.multiplicities.push_back(int(c.number()));
        total += curve.multiplicities.back();
    }
    curve.multiplicities.front() += 1;
    curve.multiplicities.back() += 1;
    const int poles = total - curve.degree + 1;
    if (!c.ok || poles < 2) return why = QObject::tr("полюса B-сплайн кривой ACIS"), false;
    for (int i = 0; i < poles; ++i) {
        curve.poles.push_back(place.point(c.triple()));
        curve.weights.push_back(rational ? c.number() : 1.0);
    }
    curve.periodic = false;
    return c.ok || (why = QObject::tr("данные B-сплайн кривой ACIS"), false);
}

// Skips a 2D curve (a parameter curve in an intersection's record).
void bs2Curve(Cursor& c, kernel::BSplineCurveDefinition* definition = nullptr) {
    if (c.isWord("nullbs")) return void(c.word());
    if (c.isWord("full") || c.isWord("summary")) c.word();
    const std::string type = c.word();
    if (type != "nubs" && type != "nurbs") return void(c.ok=false);
    const bool rational = type == "nurbs";
    const int degree = int(c.number());
    c.word();
    const int count = int(c.number());
    if (!c.ok || degree < 1 || count < 2 || count > 1000000) return void(c.ok=false);
    int total = 0;
    for (int i = 0; i < count && c.ok; ++i) {
        const double knot=c.number(); const int multiplicity=int(c.number()); total+=multiplicity;
        if (definition) { definition->knots.push_back(knot); definition->multiplicities.push_back(multiplicity); }
    }
    if (total-degree+1<2 || total-degree+1>1000000) return void(c.ok=false);
    if (definition) { definition->degree=degree; ++definition->multiplicities.front(); ++definition->multiplicities.back(); }
    for (int i = 0; i < total - degree + 1 && c.ok; ++i) {
        const double x=c.number(), y=c.number(), w=rational?c.number():1.0;
        if (definition) { definition->poles.push_back({x,y,0}); definition->weights.push_back(w); }
    }
}

bool bs3Surface(Cursor& c, const Placement& place, kernel::BSplineSurfaceDefinition& surface, QString& why) {
    if (c.isWord("full") || c.isWord("summary")) c.word();
    const std::string type = c.word();
    if (type != "nurbs" && type != "nubs") {
        why = QObject::tr("B-сплайн поверхность ACIS «%1»").arg(QString::fromStdString(type));
        return false;
    }
    const bool rational = type == "nurbs";
    surface.uDegree = int(c.number());
    surface.vDegree = int(c.number());
    c.word(); // u closure
    c.word(); // v closure
    while (c.is(Token::Kind::Word)) c.word(); // singularities (none, …), where written
    const int uCount = int(c.number()), vCount = int(c.number());
    if (!c.ok || surface.uDegree < 1 || surface.vDegree < 1 || uCount < 2 || vCount < 2)
        return why = QObject::tr("узлы B-сплайн поверхности ACIS"), false;
    int uTotal = 0, vTotal = 0;
    for (int i = 0; i < uCount; ++i) {
        surface.uKnots.push_back(c.number());
        surface.uMultiplicities.push_back(int(c.number()));
        uTotal += surface.uMultiplicities.back();
    }
    for (int i = 0; i < vCount; ++i) {
        surface.vKnots.push_back(c.number());
        surface.vMultiplicities.push_back(int(c.number()));
        vTotal += surface.vMultiplicities.back();
    }
    surface.uMultiplicities.front() += 1;
    surface.uMultiplicities.back() += 1;
    surface.vMultiplicities.front() += 1;
    surface.vMultiplicities.back() += 1;
    surface.uPoleCount = uTotal - surface.uDegree + 1;
    surface.vPoleCount = vTotal - surface.vDegree + 1;
    if (!c.ok || surface.uPoleCount < 2 || surface.vPoleCount < 2 || surface.uPoleCount > 100000 / surface.vPoleCount)
        return why = QObject::tr("полюса B-сплайн поверхности ACIS"), false;
    // ACIS writes u fastest; the builder's first layout is v fastest (index u·nv + v).
    const std::size_t n = std::size_t(surface.uPoleCount * surface.vPoleCount);
    surface.poles.assign(n, {});
    surface.weights.assign(n, 1.0);
    for (int v = 0; v < surface.vPoleCount; ++v)
        for (int u = 0; u < surface.uPoleCount; ++u) {
            const std::size_t i = std::size_t(u * surface.vPoleCount + v);
            surface.poles[i] = place.point(c.triple());
            if (rational) surface.weights[i] = c.number();
        }
    return c.ok || (why = QObject::tr("данные B-сплайн поверхности ACIS"), false);
}

// A surface: its kind, frame and sizes as the builder's patch holds them, and whether its natural normal
// is reversed against the builder's (the spline's own "reversed").
struct Surface {
    kernel::AnalyticFacePatch::Kind kind = kernel::AnalyticFacePatch::Kind::Plane;
    Vector3 origin, normal{0, 0, 1}, xAxis{1, 0, 0};
    double radius = 0, semiAngle = 0, majorRadius = 0, minorRadius = 0;
    kernel::BSplineSurfaceDefinition bspline;
    kernel::AnalyticEdgeSegment section;
    Vector3 sweep;
    SurfaceFunction value; // procedural definition, with ACIS's original parameters
    double approximationDeviation = 0.0;
    std::shared_ptr<kernel::RollingBallBlend> blend; // kind Blend: a rolling-ball blend (rbblnsur)
    bool reversed = false;
    bool null = false;

    kernel::AnalyticSurfaceSupport support() const {
        kernel::AnalyticSurfaceSupport s;
        using K = kernel::AnalyticSurfaceSupport::Kind;
        using P = kernel::AnalyticFacePatch::Kind;
        s.kind = kind == P::Plane ? K::Plane : kind == P::Cylinder ? K::Cylinder : kind == P::Cone ? K::Cone
               : kind == P::Sphere ? K::Sphere : kind == P::Torus ? K::Torus : kind == P::Blend ? K::Blend
               : kind == P::Swept ? K::Swept : K::BSpline;
        s.blend = blend;
        s.origin = origin;
        s.normal = normal;
        s.xAxis = xAxis;
        s.radius = radius;
        s.semiAngle = semiAngle;
        s.majorRadius = majorRadius;
        s.minorRadius = minorRadius;
        s.bspline = bspline;
        if (kind == P::Swept) { s.edge = std::make_shared<kernel::AnalyticEdgeSegment>(section); s.normal = sweep; }
        return s;
    }
};

bool subtype(Cursor& c, const Placement& place, bool surface, Surface* s, struct Curve* curve, QString& why);

// Surface data as a surface record holds it after ENTITY's fields, or as an intersection curve's record
// holds its surfaces after their keyword (plane, cone, sphere, torus, spline).
bool surfaceData(Cursor& c, const std::string& kind, const Placement& place, Surface& s, QString& why) {
    using P = kernel::AnalyticFacePatch::Kind;
    // Bounds of the surface's (and a cone's base ellipse's) parameters, written from 1.06 on.
    const auto intervals = [&](int ends) {
        if (c.file->version < 106) return;
        for (int i = 0; i < ends && c.atIntervalEnd(); ++i) c.intervalEnd();
    };
    if (kind == "plane") {
        s.kind = P::Plane;
        s.origin = place.point(c.triple());
        s.normal = place.direction(c.triple());
        const Vector3 u = c.triple();
        s.xAxis = norm(u) > 0 ? place.direction(u) : Vector3{1, 0, 0};
        if (c.isLogical() || c.is(Token::Kind::Number)) c.logical(); // v reversed: parametrisation only
        intervals(4);
    } else if (kind == "cone") {
        const Vector3 centre = c.triple(), axis = c.triple(), major = c.triple();
        const double ratio = c.number();
        intervals(2);
        const double sine = c.number(), cosine = c.number();
        // Then, by version: a u scale (a number followed by the u-reversed logical), or the logical alone
        // (a word, or 0/1 in early files).
        if (c.is(Token::Kind::Number) && c.isLogical(1)) c.number();
        if (c.isLogical() || c.is(Token::Kind::Number)) c.logical();
        intervals(4);
        if (!c.ok) return why = QObject::tr("данные конуса ACIS"), false;
        if (std::fabs(ratio - 1.0) > 1e-12)
            return why = QObject::tr("эллиптический цилиндр или конус (отношение осей %1) — таких в образцах нет").arg(ratio), false;
        // A negative cosine turns the natural normal toward the axis; the locus stays the one of the
        // half-angle whose tangent is sine/cosine (all the vertices of the Mechanical Desktop samples'
        // such cones lie on it, none on the cone of sine/|cosine|).
        s.reversed = cosine < 0.0;
        s.origin = place.point(centre);
        s.normal = place.direction(axis);
        s.xAxis = place.direction(major);
        s.radius = place.length(norm(major));
        if (std::fabs(sine) < 1e-14) {
            s.kind = P::Cylinder;
        } else {
            s.kind = P::Cone;
            s.semiAngle = cosine < 0.0 ? std::atan2(-sine, -cosine) : std::atan2(sine, cosine);
        }
    } else if (kind == "sphere") {
        s.kind = P::Sphere;
        s.origin = place.point(c.triple());
        const double radius = c.number();
        if (c.is(Token::Kind::Number) && c.is(Token::Kind::Number, 5)) {
            s.xAxis = place.direction(c.triple());
            s.normal = place.direction(c.triple());
        }
        if (c.isLogical() || c.is(Token::Kind::Number)) c.logical();
        intervals(4);
        if (radius < 0.0) return why = QObject::tr("сфера с отрицательным радиусом (нормаль внутрь) — таких в образцах нет"), false;
        s.radius = place.length(radius);
    } else if (kind == "torus") {
        s.kind = P::Torus;
        s.origin = place.point(c.triple());
        s.normal = place.direction(c.triple());
        const double major = c.number(), minor = c.number();
        if (c.is(Token::Kind::Number) && c.is(Token::Kind::Number, 2)) s.xAxis = place.direction(c.triple());
        if (c.isLogical() || c.is(Token::Kind::Number)) c.logical();
        intervals(4);
        // A negative minor radius turns the natural normal toward the spine circle (a concave fillet);
        // the locus is the tube of the radius's size, as the samples' vertices show.
        s.reversed = minor < 0.0;
        s.majorRadius = place.length(std::fabs(major));
        s.minorRadius = place.length(std::fabs(minor));
        if (major < 0.0) return why = QObject::tr("тор с отрицательным большим радиусом — таких в образцах нет"), false;
    } else if (kind == "spline") {
        s.kind = P::BSpline;
        s.reversed = c.logical();
        if (!c.is(Token::Kind::Open)) return why = QObject::tr("сплайн-поверхность ACIS без определения"), false;
        ++c.at;
        if (!subtype(c, place, true, &s, nullptr, why)) return false;
        intervals(4);
    } else if (kind == "null_surface") {
        s.null = true;
    } else {
        return why = QObject::tr("поверхность ACIS «%1»").arg(QString::fromStdString(kind)), false;
    }
    return c.ok || (why = QObject::tr("данные поверхности ACIS «%1»").arg(QString::fromStdString(kind)), false);
}

struct Curve {
    kernel::AnalyticEdgeKind kind = kernel::AnalyticEdgeKind::Line;
    Vector3 center, normal, xAxis;
    double radius = 0, majorRadius = 0, minorRadius = 0;
    kernel::BSplineCurveDefinition bspline; // exact (BSpline), or an intersection's approximation
    std::array<Surface, 2> surfaces;
    double fit = 0; // the approximation's own tolerance, for an intersection
    double linearScale = 1.0; // a straight curve's parameter is a length in the original model units
    bool reversed = false; // an intcurve's direction against its B-spline's
    bool null = false;     // null_curve (a blend support's)
    // offintcur: the intersection of its two surfaces each offset (a blend's spine; the offsets are the
    // blend's). The approximation then has no fit tolerance of its own (ACIS writes 1000).
    bool offset = false;
    // bldcur, blndsprngcur: where a blend touches a support — the blend is the surface of `surfaces`
    // that is one; which support it touches is told by the edge's vertices.
    std::shared_ptr<kernel::RollingBallBlend> blend;
    CurveFunction value; // a law or a parameter curve evaluated from its definition
    double approximationDeviation = 0.0;
    bool blendSection = false; // a parcur at constant spine parameter: an exact circular cross-section
    bool exactParameters = false; // exactcur, whose edge interval can be kept without vertex projection
    int blendBoundary = -1; // the support named by the curve's pcurve (u = 0 or 1)
    kernel::BSplineCurveDefinition blendParameters;
};

bool curveData(Cursor& c, const std::string& kind, const Placement& place, Curve& curve, QString& why);
bool rollingBall(Cursor& c, const Placement& place, Surface& s, QString& why);
bool sumSurface(Cursor& c, const Placement& place, Surface& s, QString& why);
bool sweepSurface(Cursor& c, const Placement& place, Surface& s, QString& why);
bool parameterCurve(Cursor& c, const Placement& place, Curve& curve, QString& why);
bool proceduralCurve(Cursor& c, const std::string& name, const Placement& place, Curve& curve, QString& why);
Vector3 evaluate(const kernel::BSplineCurveDefinition& d, double t);
bool footOn(const kernel::AnalyticSurfaceSupport& s, const Vector3& p, Vector3& f);

#ifdef CADNEXT_WITH_OCCT
Vector3 coordinates(const gp_Pnt& p) { return {p.X(),p.Y(),p.Z()}; }
gp_Pnt pointOf(const Vector3& p) { return {p.x,p.y,p.z}; }

Handle(Geom_BSplineCurve) splineCurve(const kernel::BSplineCurveDefinition& d) {
    const int np=int(d.poles.size()), nk=int(d.knots.size());
    if (np<2 || nk<2 || int(d.weights.size())!=np || int(d.multiplicities.size())!=nk) return {};
    TColgp_Array1OfPnt poles(1,np);
    TColStd_Array1OfReal weights(1,np), knots(1,nk);
    TColStd_Array1OfInteger multiplicities(1,nk);
    for (int i=0;i<np;++i) { poles(i+1)=pointOf(d.poles[size_t(i)]); weights(i+1)=d.weights[size_t(i)]; }
    for (int i=0;i<nk;++i) { knots(i+1)=d.knots[size_t(i)]; multiplicities(i+1)=d.multiplicities[size_t(i)]; }
    return new Geom_BSplineCurve(poles,weights,knots,multiplicities,d.degree,d.periodic);
}

Handle(Geom_BSplineSurface) splineSurface(const kernel::BSplineSurfaceDefinition& d) {
    if (d.uPoleCount<2 || d.vPoleCount<2 || d.poles.size()!=size_t(d.uPoleCount*d.vPoleCount) ||
        d.weights.size()!=d.poles.size() || d.uKnots.size()<2 || d.vKnots.size()<2 ||
        d.uMultiplicities.size()!=d.uKnots.size() || d.vMultiplicities.size()!=d.vKnots.size()) return {};
    TColgp_Array2OfPnt poles(1,d.uPoleCount,1,d.vPoleCount);
    TColStd_Array2OfReal weights(1,d.uPoleCount,1,d.vPoleCount);
    for (int u=0;u<d.uPoleCount;++u) for (int v=0;v<d.vPoleCount;++v) {
        const size_t i=size_t(u*d.vPoleCount+v); poles(u+1,v+1)=pointOf(d.poles[i]); weights(u+1,v+1)=d.weights[i];
    }
    TColStd_Array1OfReal uk(1,int(d.uKnots.size())), vk(1,int(d.vKnots.size()));
    TColStd_Array1OfInteger um(1,int(d.uKnots.size())), vm(1,int(d.vKnots.size()));
    for (int i=0;i<int(d.uKnots.size());++i) {uk(i+1)=d.uKnots[size_t(i)];um(i+1)=d.uMultiplicities[size_t(i)];}
    for (int i=0;i<int(d.vKnots.size());++i) {vk(i+1)=d.vKnots[size_t(i)];vm(i+1)=d.vMultiplicities[size_t(i)];}
    return new Geom_BSplineSurface(poles,weights,uk,vk,um,vm,d.uDegree,d.vDegree,d.uPeriodic,d.vPeriodic);
}

kernel::BSplineCurveDefinition describeSpline(const Handle(Geom_BSplineCurve)& c) {
    kernel::BSplineCurveDefinition d;
    d.degree=c->Degree();d.periodic=c->IsPeriodic();
    for (int i=1;i<=c->NbPoles();++i) {d.poles.push_back(coordinates(c->Pole(i)));d.weights.push_back(c->Weight(i));}
    for (int i=1;i<=c->NbKnots();++i) {d.knots.push_back(c->Knot(i));d.multiplicities.push_back(c->Multiplicity(i));}
    return d;
}

kernel::BSplineSurfaceDefinition describeSpline(const Handle(Geom_BSplineSurface)& s) {
    kernel::BSplineSurfaceDefinition d;
    d.uDegree=s->UDegree();d.vDegree=s->VDegree();d.uPoleCount=s->NbUPoles();d.vPoleCount=s->NbVPoles();
    d.uPeriodic=s->IsUPeriodic();d.vPeriodic=s->IsVPeriodic();
    for (int u=1;u<=s->NbUPoles();++u) for (int v=1;v<=s->NbVPoles();++v) {
        d.poles.push_back(coordinates(s->Pole(u,v)));d.weights.push_back(s->Weight(u,v));
    }
    for (int i=1;i<=s->NbUKnots();++i) {d.uKnots.push_back(s->UKnot(i));d.uMultiplicities.push_back(s->UMultiplicity(i));}
    for (int i=1;i<=s->NbVKnots();++i) {d.vKnots.push_back(s->VKnot(i));d.vMultiplicities.push_back(s->VMultiplicity(i));}
    return d;
}
#endif

CurveFunction curveValue(const Curve& curve) {
    CurveFunction value=curve.value;
    using E=kernel::AnalyticEdgeKind;
    if (!value && curve.kind==E::Line)
        value=[o=curve.center,n=curve.normal,scale=curve.linearScale](double t){return sum(o,scaled(n,t*scale));};
    if (!value && (curve.kind==E::Circle || curve.kind==E::Ellipse)) {
        const double a=curve.kind==E::Circle?curve.radius:curve.majorRadius;
        const double b=curve.kind==E::Circle?curve.radius:curve.minorRadius;
        value=[o=curve.center,x=curve.xAxis,y=cross(curve.normal,curve.xAxis),a,b](double t){
            return sum(o,sum(scaled(x,a*std::cos(t)),scaled(y,b*std::sin(t))));
        };
    }
    if (!value && !curve.bspline.poles.empty()) {
#ifdef CADNEXT_WITH_OCCT
        const auto c=splineCurve(curve.bspline);
        if (!c.IsNull()) value=[c](double t){return coordinates(c->Value(t));};
#else
        value=[d=curve.bspline](double t){return evaluate(d,t);};
#endif
    }
    if (value && curve.reversed) return [value](double t){return value(-t);};
    return value;
}

Vector3 derivative(const CurveFunction& value, double t) {
    // Five-point differentiation of an analytic law (or OCCT's spline evaluator); the central
    // stencil avoids a preferred side at the sweep's frame. The step is in original parameters.
    constexpr double h=1e-4;
    return scaled(sum(subtract(scaled(value(t+h),8),scaled(value(t-h),8)),
                      subtract(value(t-2*h),value(t+2*h))),1/(12*h));
}

SurfaceFunction surfaceValue(const Surface& surface) {
    if (surface.value) return surface.value;
#ifdef CADNEXT_WITH_OCCT
    Handle(Geom_Surface) s;
    if (surface.kind==kernel::AnalyticFacePatch::Kind::BSpline) s=splineSurface(surface.bspline);
    if (!s.IsNull()) return [s](double u,double v){return coordinates(s->Value(u,v));};
#endif
    return {};
}

bool fitCurve(const CurveFunction& value, double from, double to, double tolerance,
              kernel::BSplineCurveDefinition& definition, double& deviation, QString& why) {
#ifdef CADNEXT_WITH_OCCT
    if (!value || !(to>from) || !(tolerance>0)) return why=QObject::tr("интервал процедурной кривой ACIS"),false;
    try {
        for (int intervals=32;intervals<=8192;intervals*=2) {
            TColgp_Array1OfPnt points(1,intervals+1);TColStd_Array1OfReal parameters(1,intervals+1);
            for (int i=0;i<=intervals;++i) {
                const double t=from+(to-from)*i/intervals;
                points(i+1)=pointOf(value(t));parameters(i+1)=t;
            }
            GeomAPI_PointsToBSpline fit(points,parameters,3,5,GeomAbs_C2,tolerance*.1);
            if (!fit.IsDone()) continue;
            const auto spline=fit.Curve();deviation=0;
            for (int i=0;i<intervals;++i) for (double part:{.25,.5,.75}) {
                const double t=from+(to-from)*(i+part)/intervals;
                deviation=std::max(deviation,spline->Value(t).Distance(pointOf(value(t))));
            }
            if (std::isfinite(deviation) && deviation<=tolerance) {definition=describeSpline(spline);return true;}
        }
        why=QObject::tr("процедурная кривая ACIS не сходится к допуску %1 (отклонение %2)").arg(tolerance).arg(deviation);
    } catch (const Standard_Failure& e) { why=QString::fromLatin1(e.GetMessageString()); }
    return false;
#else
    Q_UNUSED(value);Q_UNUSED(from);Q_UNUSED(to);Q_UNUSED(tolerance);Q_UNUSED(definition);Q_UNUSED(deviation);
    return why=QObject::tr("процедурная кривая ACIS требует OCCT"),false;
#endif
}

bool fitSurface(const SurfaceFunction& value, double u0,double u1,double v0,double v1,
                bool linearU,bool closedU,double tolerance, Surface& surface,QString& why) {
#ifdef CADNEXT_WITH_OCCT
    if (!(u1>u0 && v1>v0 && tolerance>0) || !value) return why=QObject::tr("интервал протяжки ACIS"),false;
    try {
        int nu=linearU?4:32,nv=std::max(16,int(std::ceil((v1-v0)*12)));
        for (int iteration=0;iteration<10;++iteration) {
            if ((nu+3)>100000/(nv+3)) break;
            // Tensor interpolation with explicit parameters. GeomAPI's surface interpolator can
            // redistribute its V parameters on dense grids; a parcur must keep ACIS's exact u/v.
            Handle(TColStd_HArray1OfReal) vp=new TColStd_HArray1OfReal(1,nv+1),up=new TColStd_HArray1OfReal(1,nu+1);
            for (int v=0;v<=nv;++v) vp->SetValue(v+1,v0+(v1-v0)*v/nv);
            for (int u=0;u<=nu;++u) up->SetValue(u+1,u0+(u1-u0)*u/nu);
            std::vector<Handle(Geom_BSplineCurve)> columns;
            for (int u=0;u<=nu;++u) {
                Handle(TColgp_HArray1OfPnt) points=new TColgp_HArray1OfPnt(1,nv+1);
                for (int v=0;v<=nv;++v) points->SetValue(v+1,pointOf(value(up->Value(u+1),vp->Value(v+1))));
                GeomAPI_Interpolate fit(points,vp,false,std::min(1e-9,tolerance*.01));fit.Perform();
                if (!fit.IsDone()) return why=QObject::tr("интерполяция пути протяжки ACIS"),false;
                columns.push_back(fit.Curve());
            }
            std::vector<Handle(Geom_BSplineCurve)> rows;
            for (int v=1;v<=columns.front()->NbPoles();++v) {
                const int count=closedU?nu:nu+1;
                Handle(TColgp_HArray1OfPnt) points=new TColgp_HArray1OfPnt(1,count);
                for (int u=0;u<count;++u) points->SetValue(u+1,columns[size_t(u)]->Pole(v));
                GeomAPI_Interpolate fit(points,up,closedU,std::min(1e-9,tolerance*.01));fit.Perform();
                if (!fit.IsDone()) return why=QObject::tr("интерполяция профиля протяжки ACIS"),false;
                rows.push_back(fit.Curve());
            }
            TColgp_Array2OfPnt poles(1,rows.front()->NbPoles(),1,columns.front()->NbPoles());
            for (int u=1;u<=poles.UpperRow();++u) for (int v=1;v<=poles.UpperCol();++v) poles(u,v)=rows[size_t(v-1)]->Pole(u);
            TColStd_Array1OfReal uk(1,rows.front()->NbKnots()),vk(1,columns.front()->NbKnots());
            TColStd_Array1OfInteger um(1,uk.Length()),vm(1,vk.Length());
            rows.front()->Knots(uk);rows.front()->Multiplicities(um);columns.front()->Knots(vk);columns.front()->Multiplicities(vm);
            Handle(Geom_BSplineSurface) spline=new Geom_BSplineSurface(poles,uk,vk,um,vm,3,3,closedU,false);
            double missU=0,missV=0,miss=0;
            const auto error=[&](double u,double v){return spline->Value(u,v).Distance(pointOf(value(u,v)));};
            for (int u=0;u<nu;++u) for (int v=0;v<nv;++v) {
                for (double part:{.25,.5,.75}) {
                    missU=std::max(missU,error(u0+(u1-u0)*(u+part)/nu,v0+(v1-v0)*v/nv));
                    missV=std::max(missV,error(u0+(u1-u0)*u/nu,v0+(v1-v0)*(v+part)/nv));
                }
                miss=std::max(miss,error(u0+(u1-u0)*(u+.5)/nu,v0+(v1-v0)*(v+.5)/nv));
            }
            for (int u=0;u<nu;++u) for (double part:{.25,.5,.75})
                missU=std::max(missU,error(u0+(u1-u0)*(u+part)/nu,v1));
            for (int v=0;v<nv;++v) for (double part:{.25,.5,.75})
                missV=std::max(missV,error(u1,v0+(v1-v0)*(v+part)/nv));
            miss=std::max({miss,missU,missV});
            if (std::isfinite(miss) && miss<=tolerance) {
                surface.kind=kernel::AnalyticFacePatch::Kind::BSpline;
                surface.bspline=describeSpline(spline);surface.value=value;
                surface.approximationDeviation=miss;
                return true;
            }
            if (!linearU && missU>missV) nu*=2;
            else nv*=2;
            why=QObject::tr("протяжка ACIS: отклонение %1 при допуске %2").arg(miss).arg(tolerance);
        }
        if (why.isEmpty()) why=QObject::tr("протяжка ACIS превысила предел полюсов");
    } catch (const Standard_Failure& e) {why=QString::fromLatin1(e.GetMessageString());}
    return false;
#else
    Q_UNUSED(value);Q_UNUSED(u0);Q_UNUSED(u1);Q_UNUSED(v0);Q_UNUSED(v1);Q_UNUSED(linearU);Q_UNUSED(closedU);Q_UNUSED(tolerance);Q_UNUSED(surface);
    return why=QObject::tr("протяжка ACIS требует OCCT"),false;
#endif
}

bool surfaceKeyword(const std::string& word) {
    return word == "plane" || word == "cone" || word == "sphere" || word == "torus" || word == "spline" || word == "null_surface";
}

// The subtype after a '{' just read: exactsur (a spline surface), rbblnsur (a rolling-ball blend),
// exactcur and surfintcur (curves), offintcur (a blend's spine), bldcur and blndsprngcur (where a blend
// touches its support), or a reference to one defined earlier. Leaves the cursor past the matching '}'.
bool subtype(Cursor& c, const Placement& place, bool surface, Surface* s, Curve* curve, QString& why) {
    const std::pair<const void*, std::size_t> here{c.tokens, c.at};
    if (c.isWord("ref")) {
        c.word();
        const long long n = static_cast<long long>(c.number());
        if (!c.ok || !c.is(Token::Kind::Close)) return why = QObject::tr("ссылка на подтип ACIS"), false;
        ++c.at;
        if (n < 0 || std::size_t(n) >= c.file->subtypes.size())
            return why = QObject::tr("ссылка на несуществующий подтип ACIS %1").arg(n), false;
        const auto [record, open] = c.file->subtypes[std::size_t(n)];
        Cursor there{c.file, &c.file->records[record].data, open + 1, true};
        return subtype(there, place, surface, s, curve, why);
    }
    const std::string name = c.word();
    // Definitions are shared by many faces and curves. Cache per body placement, including the
    // fitted surfaces: otherwise a helical seam rebuilds the entire coil a second time.
    if (surface) {
        const auto found=c.file->procedures.find(here);
        if (found!=c.file->procedures.end()) {
            const bool reversed=s->reversed;
            *s=*found->second;
            s->reversed=reversed != s->reversed;
            c.closeSubtype();
            return c.ok;
        }
    } else {
        const auto found=c.file->curves.find(here);
        if (found!=c.file->curves.end()) {
            const bool reversed=curve->reversed;
            *curve=*found->second;
            curve->reversed=reversed;
            c.closeSubtype();
            return c.ok;
        }
    }
    const bool originalSense=surface?s->reversed:curve->reversed;
    bool ok = false;
    if (surface && name == "exactsur") {
        ok = bs3Surface(c, place, s->bspline, why);
    } else if (surface && name == "sumsur") {
        ok = sumSurface(c, place, *s, why);
    } else if (surface && name == "sweepsur") {
        ok = sweepSurface(c, place, *s, why);
    } else if (surface && (name == "rbblnsur" || name == "srfsrfblndsur")) {
        // One definition for every face and edge naming it.
        if (const auto found = c.file->blends.find(here); found != c.file->blends.end()) {
            s->kind = kernel::AnalyticFacePatch::Kind::Blend;
            s->blend = found->second;
            ok = true;
        } else {
            ok = rollingBall(c, place, *s, why);
            if (ok) c.file->blends[here] = s->blend;
        }
    } else if (!surface && name == "offintcur") {
        curve->kind = kernel::AnalyticEdgeKind::SurfaceIntersection;
        curve->offset = true;
        ok = bs3Curve(c, place, curve->bspline, why);
        if (ok) c.number(); // its fit tolerance: 1000 in the samples, the approximation only a guide
    } else if (!surface && (name == "bldcur" || name == "blndsprngcur")) {
        curve->kind = kernel::AnalyticEdgeKind::BlendBoundary;
        ok = true;
        if (c.isWord("summary")) {
            // Knots only, no curve: on to its surfaces.
            while (c.ok && c.peek() && !(c.is(Token::Kind::Word) && surfaceKeyword(c.peek()->text))) ++c.at;
        } else {
            ok = bs3Curve(c, place, curve->bspline, why);
            if (ok) curve->fit = place.length(c.number());
        }
        for (int i = 0; i < 2 && ok; ++i) {
            const std::string kind = c.word();
            ok = c.ok && surfaceData(c, kind, place, curve->surfaces[i], why);
            if (ok && curve->surfaces[i].blend && !curve->blend) curve->blend = curve->surfaces[i].blend;
        }
        if (ok && !curve->blend) ok = false, why = QObject::tr("граница скругления ACIS «%1» не на скруглении").arg(QString::fromStdString(name));
        if (ok) {
            kernel::BSplineCurveDefinition uv,unused;
            bs2Curve(c,&uv);bs2Curve(c,&unused);
            if (!c.ok) return why=QObject::tr("параметры границы скругления ACIS"),false;
            if (!uv.poles.empty()) {
                curve->blendParameters=uv;
                const double u=uv.poles.front().x;
                bool constant=true;
                for (const auto& p:uv.poles) constant &= std::fabs(p.x-u)<1e-9;
                if (constant && (std::fabs(u)<1e-9 || std::fabs(u-1)<1e-9)) curve->blendBoundary=u<.5?0:1;
            }
        }
    } else if (!surface && name == "exactcur") {
        curve->kind = kernel::AnalyticEdgeKind::BSpline;
        ok = bs3Curve(c, place, curve->bspline, why);
        curve->exactParameters = ok;
    } else if (!surface && name == "parcur") {
        ok = parameterCurve(c, place, *curve, why);
    } else if (!surface && (name == "offsetintcur" || name == "lawintcur")) {
        ok = proceduralCurve(c, name, place, *curve, why);
    } else if (!surface && name == "surfintcur") {
        curve->kind = kernel::AnalyticEdgeKind::SurfaceIntersection;
        ok = bs3Curve(c, place, curve->bspline, why);
        if (ok) {
            curve->fit = place.length(c.number());
            for (int i = 0; i < 2 && ok; ++i) {
                const std::string kind = c.word();
                ok = c.ok && surfaceData(c, kind, place, curve->surfaces[i], why);
                if (ok && curve->surfaces[i].null) ok = false, why = QObject::tr("кривая пересечения ACIS без своей поверхности");
            }
            if (ok) {
                bs2Curve(c);
                bs2Curve(c);
                if (!c.ok) ok = false, why = QObject::tr("данные кривой пересечения ACIS");
            }
        }
    } else {
        why = QObject::tr("процедурный сплайн ACIS «%1» — пока не поддержан").arg(QString::fromStdString(name));
        return false;
    }
    if (!ok) return false;
    if (surface) {
        auto stored=std::make_shared<Surface>(*s);
        stored->reversed=stored->reversed != originalSense;
        c.file->procedures[here]=std::move(stored);
    } else c.file->curves[here]=std::make_shared<Curve>(*curve);
    c.closeSubtype();
    return c.ok || (why = QObject::tr("незакрытый подтип ACIS «%1»").arg(QString::fromStdString(name)), false);
}

// Curve data as a blend's support or spine holds it after its keyword (null_curve, straight, ellipse,
// intcurve).
bool curveData(Cursor& c, const std::string& kind, const Placement& place, Curve& curve, QString& why) {
    const auto intervals = [&](int ends) {
        if (c.file->version < 106) return;
        for (int i = 0; i < ends && c.atIntervalEnd(); ++i) c.intervalEnd();
    };
    if (kind == "null_curve") {
        curve.null = true;
        return true;
    }
    if (kind == "straight") {
        curve.kind = kernel::AnalyticEdgeKind::Line;
        curve.center = place.point(c.triple());
        curve.normal = place.direction(c.triple());
        curve.linearScale = place.length(1);
        intervals(2);
    } else if (kind == "ellipse") {
        const Vector3 centre = c.triple(), normal = c.triple(), major = c.triple();
        const double ratio = c.number();
        intervals(2);
        curve.center = place.point(centre);
        curve.normal = place.direction(normal);
        curve.xAxis = place.direction(major);
        if (std::fabs(ratio - 1.0) < 1e-12) {
            curve.kind = kernel::AnalyticEdgeKind::Circle;
            curve.radius = place.length(norm(major));
        } else {
            curve.kind = kernel::AnalyticEdgeKind::Ellipse;
            curve.majorRadius = place.length(norm(major));
            curve.minorRadius = place.length(norm(major) * ratio);
        }
    } else if (kind == "intcurve") {
        curve.reversed = c.logical();
        if (!c.is(Token::Kind::Open)) return why = QObject::tr("кривая ACIS без определения"), false;
        ++c.at;
        if (!subtype(c, place, false, nullptr, &curve, why)) return false;
        intervals(2);
    } else {
        return why = QObject::tr("кривая ACIS «%1»").arg(QString::fromStdString(kind)), false;
    }
    return c.ok || (why = QObject::tr("данные кривой ACIS «%1»").arg(QString::fromStdString(kind)), false);
}

// A sum surface with a straight second curve is an exact linear extrusion:
// R(u,v) = C1(u) + C2(v) - origin. Other sum surfaces are refused.
bool sumSurface(Cursor& c, const Placement& place, Surface& s, QString& why) {
    Curve section, path;
    const std::string first = c.word();
    if (!curveData(c, first, place, section, why)) return false;
    const std::string second = c.word();
    if (!curveData(c, second, place, path, why)) return false;
    const Vector3 origin = place.point(c.triple());
    if (!c.ok || section.null || path.kind != kernel::AnalyticEdgeKind::Line || path.null)
        return why = QObject::tr("суммарная поверхность ACIS без прямой образующей"), false;
    const Vector3 shift{path.center.x-origin.x, path.center.y-origin.y, path.center.z-origin.z};
    s.kind = kernel::AnalyticFacePatch::Kind::Swept;
    s.section.kind = section.kind;
    s.section.center = {section.center.x+shift.x, section.center.y+shift.y, section.center.z+shift.z};
    s.section.normal = section.normal;
    s.section.xAxis = section.xAxis;
    s.section.radius = section.radius;
    s.section.majorRadius = section.majorRadius;
    s.section.minorRadius = section.minorRadius;
    s.section.bspline = section.bspline;
    for (auto& p : s.section.bspline.poles) p = {p.x+shift.x, p.y+shift.y, p.z+shift.z};
    s.sweep = path.normal;
    s.reversed = s.reversed != section.reversed;
    const auto a=curveValue(section),b=curveValue(path);
    if (a && b) s.value=[a,b,origin](double u,double v){return subtract(sum(a(u),b(v)),origin);};
    return true;
}

// A swept profile in its supplied orthonormal frame. The orientation law fixes the first axis,
// the path's tangent fixes the third, and their cross product fixes the second. The stored spline
// supplies the parameter domain and a consistency check; its coarse poles do not define the result.
bool sweepSurface(Cursor& c, const Placement& place, Surface& s, QString& why) {
    const std::string mode=c.word();
    if (mode!="normal" && mode!="angled") return why=QObject::tr("режим протяжки ACIS «%1»").arg(QString::fromStdString(mode)),false;
    Curve section,path;
    const std::string sectionKind=c.word();
    if (!curveData(c,sectionKind,place,section,why)) return false;
    const std::string pathKind=c.word();
    if (!curveData(c,pathKind,place,path,why)) return false;
    if (c.word()!=mode) return why=QObject::tr("система координат протяжки ACIS"),false;
    c.triple(); // initial profile plane's normal; the following three axes specify the moving frame
    const Vector3 origin=place.point(c.triple());
    const Vector3 x=place.direction(c.triple()),y=place.direction(c.triple()),z=place.direction(c.triple());
    const double from=c.number(),to=c.number();
    if (c.number()!=0 || c.number()!=0) return why=QObject::tr("протяжка ACIS с дополнительным законом"),false;
    CurveFunction orientation,scale;
    if (!vectorLaw(c,orientation,why)) return false;
    if (c.number()!=0 || c.number()!=1 || c.number()!=0 || c.number()!=0)
        return why=QObject::tr("дополнительные параметры протяжки ACIS"),false;
    if (!vectorLaw(c,scale,why)) return false;
    if (c.number()!=0) return why=QObject::tr("дополнительный закон масштаба протяжки ACIS"),false;
    kernel::BSplineSurfaceDefinition guide;
    if (!bs3Surface(c,place,guide,why)) return false;
    const double guideFit=place.length(c.number());
    const auto profile=curveValue(section),spine=curveValue(path);
    if (!c.ok || !profile || !spine || !(to>from) || std::fabs(dot(x,y))>1e-6 || std::fabs(dot(x,z))>1e-6 ||
        std::fabs(dot(y,z))>1e-6 || dot(cross(x,y),z)<.999999)
        return why=QObject::tr("вырожденная система координат протяжки ACIS"),false;
    const SurfaceFunction value=[profile,spine,orientation,scale,origin,x,y,z,place](double u,double v) {
        const Vector3 tangent=unit(derivative(spine,v));
        const Vector3 proposed=place.direction(orientation(v));
        const Vector3 a=unit(subtract(proposed,scaled(tangent,dot(proposed,tangent))));
        const Vector3 b=cross(tangent,a);
        const Vector3 local=subtract(profile(u),origin),factors=scale(v);
        return sum(spine(v),sum(sum(scaled(a,dot(local,x)*factors.x),scaled(b,dot(local,y)*factors.y)),
                               scaled(tangent,dot(local,z)*factors.z)));
    };
    const double u0=guide.uKnots.front(),u1=guide.uKnots.back();
    bool closed=false;
#ifdef CADNEXT_WITH_OCCT
    try {
        const auto approximation=splineSurface(guide);
        double miss=0;
        for (int i=0;i<=8;++i) for (int j=0;j<=8;++j) {
            const double u=u0+(u1-u0)*i/8,v=from+(to-from)*j/8;
            miss=std::max(miss,approximation->Value(u,v).Distance(pointOf(value(u,v))));
        }
        if (!(miss<=2*guideFit+10*place.length(c.file->resabs)))
            return why=QObject::tr("определение протяжки ACIS расходится с её контрольным сплайном (%1)").arg(miss),false;
        closed=approximation->IsUClosed();
    } catch (const Standard_Failure& e) {return why=QString::fromLatin1(e.GetMessageString()),false;}
#endif
    if (!fitSurface(value,u0,u1,from,to,section.kind==kernel::AnalyticEdgeKind::Line,closed,
                    place.length(c.file->resabs)*.2,s,why)) return false;
    s.approximationDeviation+=section.approximationDeviation+path.approximationDeviation;
    return true;
}

// A procedural curve's common cached spline, surfaces and pcurves. Its fit is only a check: law
// and offset curves are rebuilt below from the law or the underlying curve to the model's resabs.
bool proceduralCurve(Cursor& c, const std::string& name, const Placement& place, Curve& curve, QString& why) {
    kernel::BSplineCurveDefinition guide;
    if (!bs3Curve(c,place,guide,why)) return false;
    const double fit=place.length(c.number());
    for (int i=0;i<2;++i) {
        Surface unused;const std::string kind=c.word();
        if (!surfaceData(c,kind,place,unused,why) || !unused.null)
            return why=QObject::tr("процедурная кривая ACIS с неявной опорой"),false;
    }
    bs2Curve(c);bs2Curve(c);c.intervalEnd();c.intervalEnd();c.triple();
    double from=guide.knots.front(),to=guide.knots.back();
    if (name=="lawintcur") {
        CurveFunction law;
        if (!vectorLaw(c,law,why)) return false;
        curve.value=[law,place](double t){return place.point(law(t));};
    } else {
        Curve original;const std::string kind=c.word();
        if (!curveData(c,kind,place,original,why)) return false;
        from=c.number();to=c.number();
        const Vector3 direction=place.direction(c.triple());
        ScalarFunction offset;
        if (!scalarLaw(c,offset,why)) return false;
        const auto base=curveValue(original);
        if (!base || norm(direction)<.99) return why=QObject::tr("исходная кривая смещения ACIS"),false;
        curve.value=[base,direction,offset,place](double t){
            return sum(base(t),scaled(unit(cross(derivative(base,t),direction)),place.length(offset(t))));
        };
        curve.approximationDeviation=original.approximationDeviation;
    }
    if (!c.ok || !(to>from)) return why=QObject::tr("данные процедурной кривой ACIS"),false;
    double miss=0;
    for (int i=0;i<=64;++i) {
        const double t=from+(to-from)*i/64;
        miss=std::max(miss,norm(subtract(curve.value(t),evaluate(guide,t))));
    }
    if (!(miss<=2*fit+10*place.length(c.file->resabs)))
        return why=QObject::tr("определение кривой ACIS расходится с её контрольным сплайном (%1)").arg(miss),false;
    curve.kind=kernel::AnalyticEdgeKind::BSpline;
    double deviation=0;
    if (!fitCurve(curve.value,from,to,place.length(c.file->resabs)*.03,curve.bspline,deviation,why)) return false;
    curve.approximationDeviation+=deviation;
    return true;
}

CurveFunction blendSpineValue(const kernel::RollingBallBlend& blend) {
    Curve spine;
    spine.kind=blend.spine.kind;spine.center=blend.spine.center;spine.normal=blend.spine.normal;spine.xAxis=blend.spine.xAxis;
    spine.radius=blend.spine.radius;spine.majorRadius=blend.spine.majorRadius;spine.minorRadius=blend.spine.minorRadius;
    spine.bspline=blend.spine.bspline;
    auto value=curveValue(spine);
    if (value && spine.kind==kernel::AnalyticEdgeKind::SurfaceIntersection) {
        const auto meeting=blend.spine.intersectionSurfaces;
        return [value,meeting](double t) {
            Vector3 p=value(t);
            for (int iteration=0;iteration<500;++iteration) {
                double gap=0;
                for (const auto& s:meeting) {Vector3 q;if (!footOn(s,p,q)) return p;gap=std::max(gap,norm(subtract(p,q)));p=q;}
                if (gap<1e-12) break;
            }
            return p;
        };
    }
    return value;
}

bool parameterCurve(Cursor& c, const Placement& place, Curve& curve, QString& why) {
    curve.kind=kernel::AnalyticEdgeKind::BSpline;
    const bool summary=c.isWord("summary");
    if (summary) {
        c.word();const int count=int(c.number());
        if (!c.ok || count<2 || count>100000) return why=QObject::tr("узлы параметрической кривой ACIS"),false;
        for (int i=0;i<count;++i) c.number();
    } else if (!bs3Curve(c,place,curve.bspline,why)) return false;
    curve.fit=place.length(c.number());
    if (!summary && curve.fit==0) return c.ok; // the file supplies an exact 3D curve
    if (summary) c.word(); // OPEN / PERIODIC
    std::array<kernel::BSplineCurveDefinition,2> pcurves;
    for (int i=0;i<2;++i) {
        const std::string kind=c.word();
        if (!surfaceData(c,kind,place,curve.surfaces[size_t(i)],why)) return false;
    }
    bs2Curve(c,&pcurves[0]);bs2Curve(c,&pcurves[1]);
    int on=-1;
    for (std::size_t i=c.at;c.tokens && i<c.tokens->size() && (*c.tokens)[i].kind!=Token::Kind::Close;++i) {
        const Token& token=(*c.tokens)[i];
        if (token.kind==Token::Kind::Word && token.text=="surf1") on=0;
        if (token.kind==Token::Kind::Word && token.text=="surf2") on=1;
    }
    if (!c.ok || on<0 || pcurves[size_t(on)].poles.empty()) return why=QObject::tr("опора параметрической кривой ACIS"),false;
    const auto& surface=curve.surfaces[size_t(on)];const auto& parameters=pcurves[size_t(on)];
    if (surface.blend && surface.blend->radiusLaw.poles.empty()) {
        const double v=parameters.poles.front().y;
        for (const auto& p:parameters.poles)
            if (std::fabs(p.y-v)>1e-9 || p.x<-1e-9 || p.x>1+1e-9)
                return why=QObject::tr("параметрическая кривая ACIS вдоль скругления"),false;
        const auto spine=blendSpineValue(*surface.blend);
        if (!spine) return why=QObject::tr("сечение скругления ACIS без спины"),false;
        curve.kind=kernel::AnalyticEdgeKind::Circle;curve.center=spine(v);curve.normal=unit(derivative(spine,v));
        curve.radius=surface.blend->radius;curve.blendSection=true;
        return true;
    }
    const auto support=surfaceValue(surface);
    if (!support) return why=QObject::tr("параметрическая кривая ACIS на неподдержанной поверхности"),false;
    curve.value=[support,parameters](double t){const auto uv=evaluate(parameters,t);return support(uv.x,uv.y);};
    double deviation=0;
    if (!fitCurve(curve.value,parameters.knots.front(),parameters.knots.back(),place.length(c.file->resabs)*.03,
                  curve.bspline,deviation,why)) return false;
    curve.approximationDeviation=deviation+surface.approximationDeviation;
    return true;
}

// The nearest point of an analytic support to p, in closed form; false for other kinds.
bool footOn(const kernel::AnalyticSurfaceSupport& s, const Vector3& p, Vector3& f) {
    using K = kernel::AnalyticSurfaceSupport::Kind;
    const Vector3& n = s.normal;
    const Vector3 d{p.x - s.origin.x, p.y - s.origin.y, p.z - s.origin.z};
    const double h = d.x * n.x + d.y * n.y + d.z * n.z;
    Vector3 r{d.x - h * n.x, d.y - h * n.y, d.z - h * n.z};
    const double rho = norm(r);
    if (s.kind != K::Plane && s.kind != K::Sphere) {
        if (rho < 1e-300) return false;
        r = {r.x / rho, r.y / rho, r.z / rho};
    }
    const auto at = [&](double along, double out) {
        return Vector3{s.origin.x + along * n.x + out * r.x, s.origin.y + along * n.y + out * r.y, s.origin.z + along * n.z + out * r.z};
    };
    switch (s.kind) {
    case K::Plane: f = {p.x - h * n.x, p.y - h * n.y, p.z - h * n.z}; return true;
    case K::Cylinder: f = at(h, s.radius); return true;
    case K::Cone: {
        // In the half-plane through p and the axis: the generator through (0, radius) along (cos α, sin α).
        const double ca = std::cos(s.semiAngle), sa = std::sin(s.semiAngle);
        const double t = h * ca + (rho - s.radius) * sa;
        f = at(t * ca, s.radius + t * sa);
        return true;
    }
    case K::Sphere: {
        const double l = norm(d);
        if (l < 1e-300) return false;
        f = {s.origin.x + d.x * s.radius / l, s.origin.y + d.y * s.radius / l, s.origin.z + d.z * s.radius / l};
        return true;
    }
    case K::Torus: {
        const Vector3 centre = at(0.0, s.majorRadius);
        const Vector3 e{p.x - centre.x, p.y - centre.y, p.z - centre.z};
        const double l = norm(e);
        if (l < 1e-300) return false;
        f = {centre.x + e.x * s.minorRadius / l, centre.y + e.y * s.minorRadius / l, centre.z + e.z * s.minorRadius / l};
        return true;
    }
    default: return false;
    }
}

// An analytic support moved by `d` along its natural normal (the kernel's: a plane's normal, else away
// from the axis or centre): the same kind of surface. False for other kinds.
bool offsetSupport(kernel::AnalyticSurfaceSupport& s, double d) {
    using K = kernel::AnalyticSurfaceSupport::Kind;
    switch (s.kind) {
    case K::Plane: s.origin = {s.origin.x + d * s.normal.x, s.origin.y + d * s.normal.y, s.origin.z + d * s.normal.z}; return true;
    case K::Cylinder: s.radius += d; return true;
    case K::Cone: s.radius += d / std::cos(s.semiAngle); return true; // the generator moved d across itself
    case K::Sphere: s.radius += d; return true;
    case K::Torus: s.minorRadius += d; return true;
    case K::BSpline: s.kind=K::BSplineOffset;s.offsetDistance=d;return true;
    case K::BSplineOffset: case K::Blend: s.offsetDistance+=d;return true;
    default: return false;
    }
}

// rbblnsur: a ball of constant radius rolling between two supports along its spine. Read into the
// kernel's RollingBallBlend, which builds the surface from that definition (as for Parasolid's
// BLENDED_EDGE). Each support: a number, "blendsupsur", the surface, a curve, a 2D curve, three numbers;
// then the spine (a curve), the offsets of the spine from the supports along their normals, the radius
// law ("no_radius": the offsets say it). The approximation after it is not needed.
bool rollingBall(Cursor& c, const Placement& place, Surface& s, QString& why) {
    auto definition = std::make_shared<kernel::RollingBallBlend>();
    std::array<Surface, 2> supports;
    for (int i = 0; i < 2; ++i) {
        if (c.is(Token::Kind::Number)) c.number();
        if (!c.isWord("blendsupsur")) return why = QObject::tr("опора скругления ACIS"), false;
        c.word();
        const std::string kind = c.word();
        if (!c.ok || !surfaceData(c, kind, place, supports[size_t(i)], why)) return false;
        Curve along;
        const std::string curveKind = c.word();
        if (!c.ok || !curveData(c, curveKind, place, along, why)) return false;
        if (!along.null) return why = QObject::tr("опора скругления ACIS — ребро (скругление типа «E») — таких в образцах нет"), false;
        bs2Curve(c);
        c.triple();
        if (!c.ok) return why = QObject::tr("опора скругления ACIS"), false;
    }
    Curve spine;
    const std::string spineKind = c.word();
    if (!c.ok || !curveData(c, spineKind, place, spine, why)) return false;
    const double left = c.number(), right = c.number();
    const std::string law = c.word();
    if (!c.ok) return why = QObject::tr("данные скругления ACIS"), false;
    if (law == "single_radius") {
        if (c.word()!="functional" || c.word()!="calibrated")
            return why=QObject::tr("закон переменного радиуса ACIS"),false;
        const double from=c.number(),to=c.number();
        bs2Curve(c,&definition->radiusLaw);
        if (!c.ok || definition->radiusLaw.poles.empty() || !(to>from))
            return why=QObject::tr("сплайн закона радиуса ACIS"),false;
        for (auto& p:definition->radiusLaw.poles) {
            p.x=place.length(p.x);
            if (!(p.x>0)) return why=QObject::tr("неположительный радиус скругления ACIS"),false;
            definition->radius=std::max(definition->radius,p.x);
        }
    } else if (law == "no_radius") {
        if (!(std::fabs(left) > 0) || std::fabs(std::fabs(left) - std::fabs(right)) > 1e-12 * std::fabs(left))
            return why = QObject::tr("скругление ACIS со смещениями %1 и %2: переменное сечение не поддерживается").arg(left).arg(right), false;
        definition->radius = place.length(std::fabs(left));
    } else return why=QObject::tr("скругление ACIS с законом радиуса «%1»").arg(QString::fromStdString(law)),false;
    const std::array<double, 2> offsets{left, right};
    for (int i = 0; i < 2; ++i) {
        const Surface& support = supports[size_t(i)];
        definition->supports[size_t(i)] = support.support();
        // ACIS's blend parameters run across the section first and along the spine second;
        // the kernel's rational loft runs along first and across second, reversing Su × Sv.
        // Analytic supports only reverse their natural normal for a negative cosine/minor radius.
        const double normalSense=support.kind==kernel::AnalyticFacePatch::Kind::Blend
            ? (support.reversed?1.0:-1.0) : (support.reversed?-1.0:1.0);
        definition->offsets[size_t(i)] = place.length(offsets[size_t(i)]) * normalSense;
    }
    using E = kernel::AnalyticEdgeKind;
    auto& d = definition->spine;
    d.kind = spine.kind;
    d.center = spine.center;
    d.normal = spine.normal;
    d.xAxis = spine.xAxis;
    d.radius = spine.radius;
    d.majorRadius = spine.majorRadius;
    d.minorRadius = spine.minorRadius;
    if (spine.kind == E::BSpline) {
        d.bspline = spine.bspline;
        if (spine.reversed) {
            std::reverse(d.bspline.poles.begin(),d.bspline.poles.end());
            std::reverse(d.bspline.weights.begin(),d.bspline.weights.end());
            std::reverse(d.bspline.knots.begin(),d.bspline.knots.end());
            std::reverse(d.bspline.multiplicities.begin(),d.bspline.multiplicities.end());
            for (double& t:d.bspline.knots) t=-t;
        }
    } else if (spine.kind == E::SurfaceIntersection) {
        // Where the offset supports meet (offintcur), or two surfaces of the spine's own (surfintcur):
        // the chart is the file's approximation, each point put on both by alternate projection.
        std::array<kernel::AnalyticSurfaceSupport, 2> meeting;
        for (int i = 0; i < 2; ++i) {
            meeting[size_t(i)] = spine.offset ? definition->supports[size_t(i)] : spine.surfaces[size_t(i)].support();
            if (spine.offset && !offsetSupport(meeting[size_t(i)], definition->offsets[size_t(i)]))
                return why = QObject::tr("спина скругления ACIS на смещённой неаналитической опоре — пока не поддержана"), false;
            d.intersectionSurfaces[size_t(i)] = meeting[size_t(i)];
        }
        const auto& a = spine.bspline;
        d.bspline = a; // retain the chart's original parameters for a parcur cross-section
        if (a.poles.size() < 2) return why = QObject::tr("у спины скругления ACIS нет аппроксимации"), false;
        const Vector3 &first = a.poles.front(), &last = a.poles.back();
        definition->spineClosed = norm({first.x - last.x, first.y - last.y, first.z - last.z}) < 1e-9;
        constexpr int kChart = 64;
        const double t0 = a.knots.front(), t1 = a.knots.back();
        const double scale = std::max(1e-300, definition->radius);
        const bool numeric=std::any_of(meeting.begin(),meeting.end(),[](const auto& s){
            using K=kernel::AnalyticSurfaceSupport::Kind;
            return s.kind==K::BSpline || s.kind==K::BSplineOffset || s.kind==K::Blend;
        });
        definition->spineChartApproximate=numeric;
        for (int k = 0; k <= kChart; ++k) {
            if (definition->spineClosed && k == kChart) break;
            Vector3 p = evaluate(a, t0 + (t1 - t0) * k / kChart);
            if (numeric) {definition->spineChart.push_back(p);continue;}
            double gap = 0.0;
            for (int iteration = 0; iteration < 500; ++iteration) {
                gap = 0.0;
                for (const auto& surface : meeting) {
                    Vector3 f;
                    if (!footOn(surface, p, f)) return why = QObject::tr("спина скругления ACIS — пересечение неаналитических поверхностей"), false;
                    gap = std::max(gap, norm({f.x - p.x, f.y - p.y, f.z - p.z}));
                    p = f;
                }
                if (gap < 1e-14 * scale) break;
            }
            if (!(gap < 1e-9 * scale)) return why = QObject::tr("точка спины скругления ACIS не сходится к пересечению опор"), false;
            definition->spineChart.push_back(p);
        }
    } else if (spine.kind != E::Line && spine.kind != E::Circle && spine.kind != E::Ellipse) {
        return why = QObject::tr("спина скругления ACIS — пока не поддержанная кривая"), false;
    }
    s.kind = kernel::AnalyticFacePatch::Kind::Blend;
    s.blend = std::move(definition);
    return true;
}

bool surfaceRecord(const SatFile& file, const Record& record, const Placement& place, Surface& s, QString& why) {
    Cursor c = recordData(file, record);
    const std::string& type = record.type;
    const std::size_t dash = type.find("-surface");
    if (dash == std::string::npos) return why = QObject::tr("поверхность ACIS «%1»").arg(QString::fromStdString(type)), false;
    return surfaceData(c, type.substr(0, dash), place, s, why);
}

bool curveRecord(const SatFile& file, const Record& record, const Placement& place, Curve& curve, QString& why) {
    Cursor c = recordData(file, record);
    if (record.type == "straight-curve") {
        curve.kind = kernel::AnalyticEdgeKind::Line;
        c.triple();
        c.triple();
        return c.ok || (why = QObject::tr("данные прямой ACIS"), false);
    }
    if (record.type == "ellipse-curve") {
        const Vector3 centre = c.triple(), normal = c.triple(), major = c.triple();
        const double ratio = c.number();
        if (!c.ok) return why = QObject::tr("данные эллипса ACIS"), false;
        curve.center = place.point(centre);
        curve.normal = place.direction(normal);
        curve.xAxis = place.direction(major);
        if (std::fabs(ratio - 1.0) < 1e-12) {
            curve.kind = kernel::AnalyticEdgeKind::Circle;
            curve.radius = place.length(norm(major));
        } else {
            curve.kind = kernel::AnalyticEdgeKind::Ellipse;
            curve.majorRadius = place.length(norm(major));
            curve.minorRadius = place.length(norm(major) * ratio);
        }
        return true;
    }
    if (record.type == "intcurve-curve") {
        curve.reversed = c.logical();
        if (!c.is(Token::Kind::Open)) return why = QObject::tr("кривая ACIS без определения"), false;
        ++c.at;
        return subtype(c, place, false, nullptr, &curve, why);
    }
    return why = QObject::tr("кривая ACIS «%1»").arg(QString::fromStdString(record.type)), false;
}

// A point of a (possibly rational) B-spline curve at t, by de Boor on the full knot vector.
Vector3 evaluate(const kernel::BSplineCurveDefinition& d, double t) {
    std::vector<double> knots;
    for (std::size_t i = 0; i < d.knots.size(); ++i) knots.insert(knots.end(), std::size_t(d.multiplicities[i]), d.knots[i]);
    const int p = d.degree, n = int(d.poles.size());
    int span = p;
    while (span + 1 < n && t >= knots[std::size_t(span + 1)]) ++span;
    std::vector<std::array<double, 4>> w(std::size_t(p + 1));
    for (int j = 0; j <= p; ++j) {
        const auto& pole = d.poles[std::size_t(span - p + j)];
        const double weight = d.weights[std::size_t(span - p + j)];
        w[std::size_t(j)] = {pole.x * weight, pole.y * weight, pole.z * weight, weight};
    }
    for (int r = 1; r <= p; ++r)
        for (int j = p; j >= r; --j) {
            const double a0 = knots[std::size_t(span - p + j)], a1 = knots[std::size_t(span + 1 + j - r)];
            const double alpha = a1 > a0 ? (t - a0) / (a1 - a0) : 0.0;
            for (int k = 0; k < 4; ++k) w[std::size_t(j)][k] = (1 - alpha) * w[std::size_t(j - 1)][k] + alpha * w[std::size_t(j)][k];
        }
    const auto& q = w[std::size_t(p)];
    return {q[0] / q[3], q[1] / q[3], q[2] / q[3]};
}

// The parameter of the curve's point nearest p: a dense sampling, then golden sections about the best.
double nearestParameter(const kernel::BSplineCurveDefinition& d, const Vector3& p) {
    const double t0 = d.knots.front(), t1 = d.knots.back();
    const auto distance = [&](double t) {
        const Vector3 q = evaluate(d, t);
        return norm({q.x - p.x, q.y - p.y, q.z - p.z});
    };
    constexpr int kSamples = 512;
    int best = 0;
    double nearest = std::numeric_limits<double>::infinity();
    for (int i = 0; i <= kSamples; ++i)
        if (const double dd = distance(t0 + (t1 - t0) * i / kSamples); dd < nearest) nearest = dd, best = i;
    double a = t0 + (t1 - t0) * std::max(0, best - 1) / kSamples, b = t0 + (t1 - t0) * std::min(kSamples, best + 1) / kSamples;
    const double golden = (std::sqrt(5.0) - 1) / 2;
    for (int i = 0; i < 80; ++i) {
        const double c = b - golden * (b - a), e = a + golden * (b - a);
        if (distance(c) < distance(e)) b = e;
        else a = c;
    }
    return (a + b) / 2;
}

// How far p lies off an analytic surface (0 for a spline: the builder measures those itself).
enum class Shape { Plane, Cylinder, Cone, Sphere, Torus, Other };

double surfaceDistance(Shape shape, const Vector3& o, const Vector3& n, double radius, double semiAngle, double major,
                       double minor, const Vector3& p) {
    const Vector3 d{p.x - o.x, p.y - o.y, p.z - o.z};
    const double axial = d.x * n.x + d.y * n.y + d.z * n.z;
    const double radial = norm({d.x - axial * n.x, d.y - axial * n.y, d.z - axial * n.z});
    switch (shape) {
    case Shape::Plane: return std::fabs(axial);
    case Shape::Cylinder: return std::fabs(radial - radius);
    case Shape::Cone: return std::fabs(radial - radius - axial * std::tan(semiAngle)) * std::cos(semiAngle);
    case Shape::Sphere: return std::fabs(norm(d) - radius);
    case Shape::Torus: return std::fabs(std::hypot(radial - major, axial) - minor);
    case Shape::Other: break;
    }
    return 0.0;
}

Shape shapeOf(kernel::AnalyticFacePatch::Kind kind) {
    using K = kernel::AnalyticFacePatch::Kind;
    return kind == K::Plane ? Shape::Plane : kind == K::Cylinder ? Shape::Cylinder : kind == K::Cone ? Shape::Cone
         : kind == K::Sphere ? Shape::Sphere : kind == K::Torus ? Shape::Torus : Shape::Other;
}

Shape shapeOf(kernel::AnalyticSurfaceSupport::Kind kind) {
    using K = kernel::AnalyticSurfaceSupport::Kind;
    return kind == K::Plane ? Shape::Plane : kind == K::Cylinder ? Shape::Cylinder : kind == K::Cone ? Shape::Cone
         : kind == K::Sphere ? Shape::Sphere : kind == K::Torus ? Shape::Torus : Shape::Other;
}

// How far p lies off a segment's own curve: a circle or ellipse (in its plane and out of it), a B-spline,
// or for an intersection each of its two surfaces. 0 for a line (built from its ends).
double curveDistance(const kernel::AnalyticEdgeSegment& s, const Vector3& p) {
    using E = kernel::AnalyticEdgeKind;
    const Vector3 d{p.x - s.center.x, p.y - s.center.y, p.z - s.center.z};
    const double h = d.x * s.normal.x + d.y * s.normal.y + d.z * s.normal.z;
    const Vector3 inPlane{d.x - h * s.normal.x, d.y - h * s.normal.y, d.z - h * s.normal.z};
    switch (s.kind) {
    case E::Circle: return std::hypot(norm(inPlane) - s.radius, h);
    case E::Ellipse: {
        const Vector3& x = s.xAxis;
        const Vector3 y{s.normal.y * x.z - s.normal.z * x.y, s.normal.z * x.x - s.normal.x * x.z, s.normal.x * x.y - s.normal.y * x.x};
        const double u = inPlane.x * x.x + inPlane.y * x.y + inPlane.z * x.z, v = inPlane.x * y.x + inPlane.y * y.y + inPlane.z * y.z;
        const auto distance=[&](double a){return std::hypot(u-s.majorRadius*std::cos(a),v-s.minorRadius*std::sin(a));};
        constexpr double step=2*3.14159265358979323846/64;
        int best=0;double gap=std::numeric_limits<double>::infinity();
        for (int i=0;i<64;++i) if (const double e=distance(i*step);e<gap) {gap=e;best=i;}
        double first=(best-1)*step,last=(best+1)*step;
        const double golden=(std::sqrt(5.)-1)/2;
        for (int i=0;i<80;++i) {
            const double a=last-golden*(last-first),b=first+golden*(last-first);
            if (distance(a)<distance(b)) last=b;else first=a;
        }
        return std::hypot(distance((first+last)/2),h);
    }
    case E::BSpline: {
        const Vector3 q = evaluate(s.bspline, nearestParameter(s.bspline, p));
        return norm({q.x - p.x, q.y - p.y, q.z - p.z});
    }
    case E::SurfaceIntersection: {
        double worst = 0.0;
        for (const auto& support : s.intersectionSurfaces)
            worst = std::max(worst, surfaceDistance(shapeOf(support.kind), support.origin, support.normal, support.radius,
                                                    support.semiAngle, support.majorRadius, support.minorRadius, p));
        return worst;
    }
    default: return 0.0;
    }
}

// --- Topology --------------------------------------------------------------------------------------

struct Edge {
    long long start = -1, end = -1, curve = -1;
    bool reversed = false;
    // The vertices' parameters, where the version writes them: along the edge, the curve's own negated
    // when the edge runs against it.
    bool hasParameters = false;
    double startParameter = 0, endParameter = 0;
};

bool edgeRecord(const SatFile& file, const Record& record, Edge& edge) {
    Cursor c = recordData(file, record);
    edge.start = c.pointer();
    edge.hasParameters = c.is(Token::Kind::Number);
    if (edge.hasParameters) edge.startParameter = c.number(); // its parameter, from some version on
    edge.end = c.pointer();
    if (c.is(Token::Kind::Number)) edge.endParameter = c.number();
    c.pointer(); // a coedge
    edge.curve = c.pointer();
    edge.reversed = c.logical();
    return c.ok;
}

bool vertexPoint(const SatFile& file, long long vertex, const Placement& place, Vector3& point) {
    const Record* v = file.record(vertex);
    if (!v || v->type.size() < 6 || v->type.compare(v->type.size() - 6, 6, "vertex") != 0) return false;
    Cursor c = recordData(file, *v);
    c.pointer(); // an edge
    if (c.is(Token::Kind::Number)) c.number(); // ASM: an index after it
    const Record* p = file.record(c.pointer());
    if (!c.ok || !p || p->type != "point") return false;
    Cursor q = recordData(file, *p);
    point = place.point(q.triple());
    return q.ok;
}

// A name attribute of the body, where the file carries one: a name_attrib record owning a string and
// pointing at the body.
QString bodyName(const SatFile& file, const Record& body) {
    for (const Record& a : file.records) {
        if (a.type.rfind("name_attrib", 0) != 0 && a.type!="cadnext_name-st-attrib") continue;
        bool owned = false;
        QString name;
        for (const Token& t : a.data) {
            if (t.kind == Token::Kind::Pointer && static_cast<long long>(t.value) == body.index) owned = true;
            if (t.kind == Token::Kind::String) {
                name = QString::fromStdString(t.text);
                const QRegularExpression escaped(QStringLiteral("\\\\U\\+([0-9a-fA-F]{4})"));
                auto matches = escaped.globalMatch(name);
                std::vector<std::pair<int, QChar>> characters;
                while (matches.hasNext()) {
                    const auto match = matches.next();
                    characters.push_back({int(match.capturedStart()), QChar(match.captured(1).toUShort(nullptr, 16))});
                }
                for (auto i = characters.rbegin(); i != characters.rend(); ++i) name.replace(i->first, 7, i->second);
            }
        }
        if (owned && !name.isEmpty()) return name;
    }
    return {};
}

// The face a coedge's loop bounds, and whether that face is reversed; -1 where the records do not say.
long long faceOfCoedge(const SatFile& file, long long coedge, bool& faceReversed, long long& surface) {
    const Record* ce = file.record(coedge);
    if (!ce) return -1;
    Cursor cc = recordData(file, *ce);
    cc.pointer(); // next
    cc.pointer(); // previous
    cc.pointer(); // partner
    cc.pointer(); // edge
    cc.logical();
    const Record* loop = file.record(cc.pointer());
    if (!cc.ok || !loop || loop->type != "loop") return -1;
    Cursor lc = recordData(file, *loop);
    lc.pointer(); // next
    lc.pointer(); // first coedge
    const long long face = lc.pointer();
    const Record* f = file.record(face);
    if (!lc.ok || !f || f->type != "face") return -1;
    Cursor fc = recordData(file, *f);
    fc.pointer(); // next
    fc.pointer(); // loop
    fc.pointer(); // shell
    fc.pointer(); // subshell
    surface = fc.pointer();
    faceReversed = fc.logical();
    return fc.ok ? face : -1;
}

// Whether two analytic supports are one surface: points of each on the other, within `tolerance`.
bool sameSupport(const kernel::AnalyticSurfaceSupport& a, const kernel::AnalyticSurfaceSupport& b, double tolerance) {
    using K=kernel::AnalyticSurfaceSupport::Kind;
    if (a.kind==K::Blend || b.kind==K::Blend) return a.kind==b.kind && a.blend==b.blend &&
        std::fabs(a.offsetDistance-b.offsetDistance)<=tolerance;
    if (a.kind==K::BSpline || b.kind==K::BSpline) {
        if (a.kind!=b.kind || a.bspline.poles.size()!=b.bspline.poles.size() || a.bspline.uKnots!=b.bspline.uKnots ||
            a.bspline.vKnots!=b.bspline.vKnots || a.bspline.uMultiplicities!=b.bspline.uMultiplicities ||
            a.bspline.vMultiplicities!=b.bspline.vMultiplicities || a.bspline.weights!=b.bspline.weights) return false;
        for (size_t i=0;i<a.bspline.poles.size();++i) if (norm(subtract(a.bspline.poles[i],b.bspline.poles[i]))>tolerance) return false;
        return true;
    }
    const Shape sa = shapeOf(a.kind), sb = shapeOf(b.kind);
    if (sa == Shape::Other || sb == Shape::Other) return false;
    const auto samples = [](const kernel::AnalyticSurfaceSupport& s) {
        const Vector3& n = s.normal;
        Vector3 x = s.xAxis;
        const double along = x.x * n.x + x.y * n.y + x.z * n.z;
        x = {x.x - along * n.x, x.y - along * n.y, x.z - along * n.z};
        if (norm(x) < 1e-12) x = std::fabs(n.x) < 0.9 ? Vector3{1, 0, 0} : Vector3{0, 1, 0};
        const double xl = norm(x);
        x = {x.x / xl, x.y / xl, x.z / xl};
        const Vector3 y{n.y * x.z - n.z * x.y, n.z * x.x - n.x * x.z, n.x * x.y - n.y * x.x};
        const Vector3& o = s.origin;
        const auto p = [&](double a, double b, double c) {
            return Vector3{o.x + a * x.x + b * y.x + c * n.x, o.y + a * x.y + b * y.y + c * n.y, o.z + a * x.z + b * y.z + c * n.z};
        };
        const double size = std::max({s.radius, s.majorRadius, 1e-3});
        switch (s.kind) {
        case K::Plane: return std::vector<Vector3>{p(0, 0, 0), p(size, 0, 0), p(0, size, 0)};
        case K::Cylinder: return std::vector<Vector3>{p(s.radius, 0, 0), p(0, s.radius, 0), p(-s.radius, 0, size)};
        case K::Cone: {
            const double t = std::tan(s.semiAngle);
            return std::vector<Vector3>{p(s.radius, 0, 0), p(0, s.radius, 0), p(-(s.radius + size * t), 0, size)};
        }
        case K::Sphere: return std::vector<Vector3>{p(s.radius, 0, 0), p(0, s.radius, 0), p(0, 0, s.radius)};
        case K::Torus:
            return std::vector<Vector3>{p(s.majorRadius + s.minorRadius, 0, 0), p(0, s.majorRadius - s.minorRadius, 0),
                                        p(-s.majorRadius, 0, s.minorRadius)};
        default: return std::vector<Vector3>{};
        }
    };
    const auto on = [&](const kernel::AnalyticSurfaceSupport& from, const kernel::AnalyticSurfaceSupport& to, Shape shape) {
        for (const Vector3& q : samples(from))
            if (surfaceDistance(shape, to.origin, to.normal, to.radius, to.semiAngle, to.majorRadius, to.minorRadius, q) > tolerance)
                return false;
        return true;
    };
    return sa == sb && on(a, b, sb) && on(b, a, sa);
}

// A lump of a body: its faces as the builder's patches, and the ACIS faces they came from.
struct LumpPatches {
    QString name;
    std::vector<kernel::AnalyticFacePatch> patches;
    std::vector<long long> faces;
    // Each segment's ACIS edge (patch, loop, segment), and for an intersection edge the file's own
    // approximation of it and its fit tolerance, m.
    std::vector<std::vector<std::vector<long long>>> edges;
    std::map<long long, std::pair<kernel::BSplineCurveDefinition, double>> approximations;
};

std::optional<kernel::BSplineCurveDefinition> explicitPCurve(const SatFile& file, long long index,
                                                           const Placement& place, const Surface& surface,
                                                           const Curve& curve, double& tolerance) {
    // Forward explicit boundaries on an exact support keep its UV frame. Other ACIS pcurve
    // forms and procedural surfaces rebuilt in a different frame still project.
    if (surface.value || surface.blend || curve.reversed ||
        (curve.kind != kernel::AnalyticEdgeKind::BSpline && curve.kind != kernel::AnalyticEdgeKind::Line &&
         curve.kind != kernel::AnalyticEdgeKind::Circle && curve.kind != kernel::AnalyticEdgeKind::Ellipse)) return {};
    const Record* record = file.record(index);
    if (!record || record->type != "pcurve") return {};
    Cursor c = recordData(file, *record);
    if (c.logical() || !c.is(Token::Kind::Open)) return {};
    ++c.at;
    if (!c.isWord("exppc")) return {};
    c.word();
    kernel::BSplineCurveDefinition d;
    bs2Curve(c, &d);
    const double fit = c.number();
    if (!std::isfinite(fit) || fit < 0 || fit > 10 * file.resabs) return {};
    Surface on;
    QString why;
    const std::string kind = c.word();
    if (!c.ok || !surfaceData(c, kind, place, on, why) ||
        !sameSupport(surface.support(), on.support(), 1e-12) || d.knots.empty()) return {};
    using P = kernel::AnalyticFacePatch::Kind;
    if (surface.kind != P::BSpline &&
        (norm(subtract(surface.origin, on.origin)) > 1e-12 || norm(subtract(surface.normal, on.normal)) > 1e-12 ||
         norm(subtract(surface.xAxis, on.xAxis)) > 1e-12)) return {};
    for (auto& uv : d.poles) {
        if (surface.kind == P::Plane) uv.x = place.length(uv.x);
        if (surface.kind == P::Plane || surface.kind == P::Cylinder || surface.kind == P::Cone)
            uv.y = place.length(uv.y);
    }
    tolerance = place.length(fit);
    return d;
}

bool collectLumps(const SatFile& file, const Placement& units, std::vector<LumpPatches>& lumps, QStringList& notes,
                  QString& error) {
    for (const Record& body : file.records) {
        if (body.type != "body") continue;
        file.procedures.clear();file.curves.clear();file.blends.clear(); // a definition's placement is per body
        Cursor c = recordData(file, body);
        long long lump = c.pointer();
        const long long wire = c.pointer();
        const long long transform = c.pointer();
        if (!c.ok) {
            error = QObject::tr("Запись тела ACIS не прочитана.");
            return false;
        }
        Placement place = units;
        if (const Record* t = transform >= 0 ? file.record(transform) : nullptr) {
            // Nine rows, a translation and a scale. In SAB (whose logicals are no numbers) its last thirteen
            // numbers: a transform has fewer header fields than other entities in ASM files. In text, after
            // the header as usual — early files write its three logicals as numbers.
            Cursor m = recordData(file, *t);
            if (file.binary) {
                std::size_t last = 0;
                for (std::size_t i = 0; i < t->data.size(); ++i)
                    if (t->data[i].kind == Token::Kind::Number) last = i;
                m.at = last >= 12 ? last - 12 : 0;
                m.ok = last >= 12;
            }
            for (double& a : place.rows) a = m.number();
            place.translation = m.triple();
            place.factor = m.number();
            if (!m.ok || !(place.factor > 0.0)) {
                error = QObject::tr("Преобразование тела ACIS не прочитано.");
                return false;
            }
        }
        if (lump < 0 && wire >= 0) {
            notes << QObject::tr("Каркасное тело ACIS пропущено: в нём нет граней");
            continue;
        }
        const QString named = bodyName(file, body);
        for (; lump >= 0;) {
            const Record* l = file.record(lump);
            if (!l || l->type != "lump") {
                error = QObject::tr("Объём тела ACIS не найден.");
                return false;
            }
            Cursor lc = recordData(file, *l);
            const long long nextLump = lc.pointer();
            long long shell = lc.pointer();
            std::vector<kernel::AnalyticFacePatch> patches;
            std::vector<long long> patchFaces;
            std::vector<std::vector<std::vector<long long>>> patchEdges;
            std::map<long long, std::pair<kernel::BSplineCurveDefinition, double>> approximations;
            for (; shell >= 0;) {
                const Record* s = file.record(shell);
                if (!s || s->type != "shell") {
                    error = QObject::tr("Оболочка тела ACIS не найдена.");
                    return false;
                }
                Cursor sc = recordData(file, *s);
                const long long nextShell = sc.pointer();
                const long long subshell = sc.pointer();
                long long face = sc.pointer();
                if (subshell >= 0) {
                    error = QObject::tr("Оболочка ACIS с подоболочками — таких в образцах нет.");
                    return false;
                }
                for (; face >= 0;) {
                    const Record* f = file.record(face);
                    if (!f || f->type != "face") {
                        error = QObject::tr("Грань тела ACIS не найдена.");
                        return false;
                    }
                    Cursor fc = recordData(file, *f);
                    const long long nextFace = fc.pointer();
                    long long loop = fc.pointer();
                    fc.pointer(); // shell
                    fc.pointer(); // subshell
                    const long long surfaceIndex = fc.pointer();
                    const bool faceReversed = fc.logical();
                    const bool doubleSided = fc.peek() && (fc.isWord("double") || (file.binary && fc.isWord("T")));
                    if (!fc.ok) {
                        error = QObject::tr("Грань ACIS %1 не прочитана.").arg(face);
                        return false;
                    }
                    if (doubleSided) {
                        error = QObject::tr("Двусторонняя грань ACIS %1: тело — лист, а не объём.").arg(face);
                        return false;
                    }
                    const Record* surfaceRec = file.record(surfaceIndex);
                    Surface surface;
                    QString why;
                    if (!surfaceRec || !surfaceRecord(file, *surfaceRec, place, surface, why)) {
                        error = QObject::tr("Грань ACIS %1: %2.").arg(face).arg(why.isEmpty() ? QObject::tr("нет поверхности") : why);
                        return false;
                    }
                    kernel::AnalyticFacePatch patch;
                    patch.kind = surface.kind;
                    patch.origin = surface.origin;
                    patch.normal = surface.normal;
                    patch.xAxis = surface.xAxis;
                    patch.radius = surface.radius;
                    patch.semiAngle = surface.semiAngle;
                    patch.majorRadius = surface.majorRadius;
                    patch.minorRadius = surface.minorRadius;
                    patch.bspline = surface.bspline;
                    patch.section = surface.section;
                    patch.sweep = surface.sweep;
                    patch.blend = surface.blend;
                    patch.approximationDeviation = surface.approximationDeviation;
                    patch.reversed = faceReversed != surface.reversed;
                    std::vector<std::vector<long long>> faceEdges;
                    std::vector<long long> partners; // each segment's partner coedge, in loop order
                    std::vector<std::vector<Vector3>> middles; // and a point inside it, where known exactly
                    for (; loop >= 0;) {
                        const Record* lr = file.record(loop);
                        if (!lr || lr->type != "loop") {
                            error = QObject::tr("Контур грани ACIS %1 не найден.").arg(face);
                            return false;
                        }
                        Cursor loopc = recordData(file, *lr);
                        const long long nextLoop = loopc.pointer();
                        const long long first = loopc.pointer();
                        std::vector<kernel::AnalyticEdgeSegment> segments;
                        std::vector<long long> loopEdges;
                        long long coedge = first;
                        for (int guard = 0; coedge >= 0; ++guard) {
                            const Record* ce = file.record(coedge);
                            if (!ce || ce->type.find("coedge") == std::string::npos || guard > 100000) {
                                error = QObject::tr("Контур грани ACIS %1 разорван.").arg(face);
                                return false;
                            }
                            Cursor cc = recordData(file, *ce);
                            const long long next = cc.pointer();
                            cc.pointer(); // previous
                            const long long partner = cc.pointer();
                            const long long edgeIndex = cc.pointer();
                            const bool coedgeReversed = cc.logical();
                            cc.pointer(); // loop
                            if (file.binary && cc.is(Token::Kind::Number)) cc.number(); // ASM loop index
                            const long long pcurveIndex = cc.pointer();
                            const Record* er = file.record(edgeIndex);
                            Edge edge;
                            if (!cc.ok || !er || !edgeRecord(file, *er, edge)) {
                                error = QObject::tr("Ребро контура грани ACIS %1 не прочитано.").arg(face);
                                return false;
                            }
                            coedge = next == first ? -1 : next;
                            // An edge without a curve: a cone's apex or a sphere's pole, which the builder's
                            // analytic faces make themselves; a face holding the apex says so.
                            if (edge.curve < 0) {
                                if (next == first && coedge == -1 && segments.empty()) patch.holdsApex = true;
                                continue;
                            }
                            const Record* cr = file.record(edge.curve);
                            Curve curve;
                            if (!cr || !curveRecord(file, *cr, place, curve, why)) {
                                error = QObject::tr("Ребро грани ACIS %1: %2.").arg(face).arg(why);
                                return false;
                            }
                            if (curve.offset) {
                                error = QObject::tr("Ребро грани ACIS %1: пересечение смещённых поверхностей (offintcur) как ребро — пока не поддержано.").arg(face);
                                return false;
                            }
                            kernel::AnalyticEdgeSegment segment;
                            segment.sourceId=std::uint64_t(edgeIndex)+1;
                            segment.kind = curve.kind;
                            Vector3 a, b;
                            if (!vertexPoint(file, edge.start, place, a) || !vertexPoint(file, edge.end, place, b)) {
                                error = QObject::tr("Вершина ребра грани ACIS %1 не прочитана.").arg(face);
                                return false;
                            }
                            segment.start = coedgeReversed ? b : a;
                            segment.end = coedgeReversed ? a : b;
                            // A circle, ellipse or intersection closing on its one vertex is a ring, as the
                            // builder takes an edge without vertices.
                            segment.hasEndpoints = !(edge.start == edge.end && (curve.kind == kernel::AnalyticEdgeKind::Circle ||
                                                                               curve.kind == kernel::AnalyticEdgeKind::Ellipse ||
                                                                               curve.kind == kernel::AnalyticEdgeKind::SurfaceIntersection ||
                                                                               curve.kind == kernel::AnalyticEdgeKind::BlendBoundary ||
                                                                               curve.kind == kernel::AnalyticEdgeKind::BSpline));
                            // Along the curve's natural direction: coedge on its edge, edge on its curve, and
                            // an intcurve on its B-spline.
                            segment.forward = (int(coedgeReversed) + int(edge.reversed) + int(curve.reversed)) % 2 == 0;
                            segment.center = curve.center;
                            segment.normal = curve.normal;
                            segment.xAxis = curve.xAxis;
                            segment.radius = curve.radius;
                            segment.majorRadius = curve.majorRadius;
                            segment.minorRadius = curve.minorRadius;
                            if (curve.blendSection) {
                                // ACIS's normalized u (0..1) crosses the circular section. Select its
                                // shorter arc from the actual vertices, independent of that u scale.
                                segment.xAxis=unit(subtract(segment.start,segment.center));
                                segment.forward=dot(cross(subtract(segment.start,segment.center),subtract(segment.end,segment.center)),
                                                    segment.normal)>=0;
                            }
                            if (curve.approximationDeviation>0)
                                segment.tolerance=std::max(segment.tolerance,1e-7+curve.approximationDeviation);
                            if (!edge.reversed) {
                                double tolerance = 0;
                                segment.pcurve = explicitPCurve(file, pcurveIndex, place, surface, curve, tolerance);
                                if (segment.pcurve) segment.tolerance = std::max(segment.tolerance, tolerance);
                            }
                            if (segment.pcurve && edge.hasParameters && !edge.reversed && !curve.reversed &&
                                (curve.kind == kernel::AnalyticEdgeKind::Circle || curve.kind == kernel::AnalyticEdgeKind::Ellipse) &&
                                edge.endParameter > edge.startParameter) {
                                // Retain a ring's original parameter phase along with its UV boundary.
                                // Resetting it to 0..2pi changes the face's seam and loses that pairing.
                                const auto at = [&](double t) {
                                    const auto y = cross(curve.normal, curve.xAxis);
                                    const double rx = curve.kind == kernel::AnalyticEdgeKind::Circle ? curve.radius : curve.majorRadius;
                                    const double ry = curve.kind == kernel::AnalyticEdgeKind::Circle ? curve.radius : curve.minorRadius;
                                    return sum(curve.center, sum(scaled(curve.xAxis, rx*std::cos(t)), scaled(y, ry*std::sin(t))));
                                };
                                const double allowed = std::max(segment.tolerance, 10 * file.resabs * place.scale * place.factor);
                                if (norm(subtract(at(edge.startParameter), a)) <= allowed &&
                                    norm(subtract(at(edge.endParameter), b)) <= allowed) {
                                    segment.curveFirst = edge.startParameter;
                                    segment.curveLast = edge.endParameter;
                                }
                            }
                            if (curve.kind == kernel::AnalyticEdgeKind::BSpline) {
                                segment.bspline = curve.bspline;
                                if (curve.exactParameters && edge.hasParameters && !curve.bspline.knots.empty()) {
                                    const double sign = edge.reversed != curve.reversed ? -1.0 : 1.0;
                                    const double from = sign * edge.startParameter, to = sign * edge.endParameter;
                                    const double lo = std::min(from, to), hi = std::max(from, to);
                                    const double margin = 1e-12 * std::max(1.0, std::fabs(hi-lo));
                                    // A curve saved already cut to its edge: keep that exact interval.
                                    // Projecting a tolerant vertex onto it can shorten the boundary.
                                    if (std::fabs(lo-curve.bspline.knots.front()) <= margin &&
                                        std::fabs(hi-curve.bspline.knots.back()) <= margin) {
                                        segment.curveFirst = lo;
                                        segment.curveLast = hi;
                                        const double gap = std::max(norm(subtract(evaluate(curve.bspline, from), a)),
                                                                    norm(subtract(evaluate(curve.bspline, to), b)));
                                        const double resolution = file.resabs * place.scale * place.factor;
                                        if (gap <= 10.0 * resolution)
                                            segment.tolerance = std::max(segment.tolerance, 1.01 * gap);
                                    }
                                }
                            }
                            if (curve.kind == kernel::AnalyticEdgeKind::BlendBoundary) {
                                // Which support the ball touches along it: the one its vertices lie on.
                                segment.blend = curve.blend;
                                const double tolerance = 10.0 * file.resabs * place.scale * place.factor;
                                std::array<double, 2> off{};
                                for (int s = 0; s < 2; ++s) {
                                    const auto& support = curve.blend->supports[size_t(s)];
                                    off[size_t(s)] = 0.0;
                                    for (const Vector3& p : {segment.start, segment.end})
                                        off[size_t(s)] = std::max(off[size_t(s)], surfaceDistance(shapeOf(support.kind), support.origin, support.normal,
                                                                                                  support.radius, support.semiAngle, support.majorRadius,
                                                                                                  support.minorRadius, p));
                                }
                                const int touched = curve.blendBoundary>=0?curve.blendBoundary:(off[0] <= off[1] ? 0 : 1);
                                if (!(off[size_t(touched)] <= tolerance) ||
                                    (curve.blendBoundary<0 && off[size_t(1 - touched)] <= tolerance)) {
                                    error = QObject::tr("Ребро грани ACIS %1: граница скругления не лежит на одной своей опоре (%2 и %3).")
                                                .arg(face).arg(off[0]).arg(off[1]);
                                    return false;
                                }
                                segment.blendBoundary = touched;
                                if (!curve.blendParameters.poles.empty() && edge.hasParameters &&
                                    curve.blend->radiusLaw.poles.empty() &&
                                    (curve.blend->spine.kind==kernel::AnalyticEdgeKind::Circle ||
                                     curve.blend->spine.kind==kernel::AnalyticEdgeKind::Ellipse)) {
                                    const double t=(edge.startParameter+edge.endParameter)*.5*(curve.reversed?-1.0:1.0);
                                    const auto uv=evaluate(curve.blendParameters,t);
                                    const auto spine=blendSpineValue(*curve.blend);
                                    Vector3 contact;
                                    if (spine && footOn(curve.blend->supports[size_t(touched)],spine(uv.y),contact)) {
                                        segment.hasBranchPoint=true;
                                        segment.branchPoint=contact;
                                    }
                                }
                            }
                            partners.push_back(partner);
                            // A point inside the edge where it is known exactly — the middle of a line, or of a circle's or
                            // ellipse's arc by the edge's parameters — to tell a blend which way round its face goes.
                            {
                                std::vector<Vector3> middle;
                                using E = kernel::AnalyticEdgeKind;
                                if (segment.hasEndpoints && curve.kind == E::Line) {
                                    middle.push_back({(a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2});
                                } else if (segment.hasEndpoints && edge.hasParameters && !curve.blendSection && (curve.kind == E::Circle || curve.kind == E::Ellipse)) {
                                    const double t = (edge.startParameter + edge.endParameter) / 2 * (edge.reversed ? -1.0 : 1.0);
                                    const Vector3& n = curve.normal;
                                    const Vector3& x = curve.xAxis;
                                    const Vector3 y{n.y * x.z - n.z * x.y, n.z * x.x - n.x * x.z, n.x * x.y - n.y * x.x};
                                    const double major = curve.kind == E::Circle ? curve.radius : curve.majorRadius;
                                    const double minor = curve.kind == E::Circle ? curve.radius : curve.minorRadius;
                                    const double ct = std::cos(t) * major, st = std::sin(t) * minor;
                                    middle.push_back({curve.center.x + ct * x.x + st * y.x, curve.center.y + ct * x.y + st * y.y,
                                                      curve.center.z + ct * x.z + st * y.z});
                                } else if (segment.hasEndpoints && curve.kind==E::BlendBoundary && segment.hasBranchPoint) {
                                    middle.push_back(segment.branchPoint);
                                }
                                middles.push_back(std::move(middle));
                            }
                            if (curve.kind == kernel::AnalyticEdgeKind::SurfaceIntersection) {
                                // Exact, from the two surfaces; the file's approximation (within its fit
                                // tolerance) as the chart that picks the branch and seeds the fallback.
                                segment.intersectionSurfaces = {curve.surfaces[0].support(), curve.surfaces[1].support()};
                                // The chart covers the edge alone (the file's curve may run on past it), in the
                                // curve's order, across its start where a closed curve's edge does.
                                const auto& d = curve.bspline;
                                const double t0 = d.knots.front(), t1 = d.knots.back();
                                const bool closed = norm({d.poles.front().x - d.poles.back().x, d.poles.front().y - d.poles.back().y,
                                                          d.poles.front().z - d.poles.back().z}) < 1e-9;
                                double from = t0, span = t1 - t0;
                                if (segment.hasEndpoints) {
                                    from = nearestParameter(d, segment.forward ? segment.start : segment.end);
                                    const double to = nearestParameter(d, segment.forward ? segment.end : segment.start);
                                    span = to - from;
                                    if (span <= 0 && closed) span += t1 - t0;
                                }
                                constexpr int kChart = 32;
                                for (int i = 0; i <= kChart; ++i) {
                                    double t = from + span * i / kChart;
                                    if (t > t1) t -= t1 - t0;
                                    segment.chart.push_back(evaluate(d, t));
                                }
                                segment.hasBranchPoint = true;
                                segment.branchPoint = segment.chart[kChart / 2];
                                segment.chartClosed = !segment.hasEndpoints;
                                if (segment.chartClosed) segment.chart.pop_back();
                            }
                            if (curve.kind == kernel::AnalyticEdgeKind::SurfaceIntersection)
                                approximations[edgeIndex] = {curve.bspline, curve.fit};
                            segments.push_back(std::move(segment));
                            loopEdges.push_back(edgeIndex);
                        }
                        if (!segments.empty()) {
                            patch.loops.push_back(std::move(segments));
                            faceEdges.push_back(std::move(loopEdges));
                        }
                        loop = nextLoop;
                    }
                    if (patch.loops.empty() && patch.kind != kernel::AnalyticFacePatch::Kind::Sphere &&
                        patch.kind != kernel::AnalyticFacePatch::Kind::Torus) {
                        error = QObject::tr("Грань ACIS %1 без контура на незамкнутой поверхности.").arg(face);
                        return false;
                    }
                    // A blend face: where along the spine it lies (its edges' ends), and which way the faces of its
                    // supports turn (a neighbour across an edge lying on a support: its outward normal against the
                    // support's natural one — a plane's normal, else away from the axis or centre).
                    if (patch.kind == kernel::AnalyticFacePatch::Kind::Blend && surface.blend) {
                        kernel::RollingBallBlend& blend = *surface.blend;
                        const double tolerance = 10.0 * file.resabs * place.scale * place.factor;
                        std::size_t k = 0;
                        for (const auto& loopSegments : patch.loops)
                            for (const auto& segment : loopSegments) {
                                const long long partner = k < partners.size() ? partners[k] : -1;
                                ++k;
                                if (segment.hasEndpoints) {
                                    std::vector<Vector3> points{segment.start};
                                    if (k - 1 < middles.size()) points.insert(points.end(), middles[k - 1].begin(), middles[k - 1].end());
                                    points.push_back(segment.end);
                                    blend.faceEdges.push_back(std::move(points));
                                }
                                bool neighbourReversed = false;
                                long long neighbourSurface = -1;
                                if (partner < 0 || faceOfCoedge(file, partner, neighbourReversed, neighbourSurface) < 0) continue;
                                const Record* sr = file.record(neighbourSurface);
                                Surface other;
                                QString ignored;
                                if (!sr || !surfaceRecord(file, *sr, place, other, ignored)) continue;
                                const kernel::AnalyticSurfaceSupport otherSupport = other.support();
                                for (int s = 0; s < 2; ++s) {
                                    const auto& support = blend.supports[size_t(s)];
                                    // A nested blend has the kernel's own parametrisation and face
                                    // sense. ACIS's forward/reversed alone does not fix its normal.
                                    if (support.kind==kernel::AnalyticSurfaceSupport::Kind::Blend) continue;
                                    if (!sameSupport(otherSupport, support, tolerance)) continue;
                                    const bool outwardAgainst = neighbourReversed != other.reversed;
                                    int sense = outwardAgainst ? -1 : 1;
                                    if (support.kind == kernel::AnalyticSurfaceSupport::Kind::Plane) {
                                        const double dot = other.normal.x * support.normal.x + other.normal.y * support.normal.y +
                                                           other.normal.z * support.normal.z;
                                        if (dot < 0) sense = -sense;
                                    }
                                    if (blend.supportFaceSense[size_t(s)] == 0) blend.supportFaceSense[size_t(s)] = sense;
                                }
                            }
                    }
                    // An ACIS model is exact to its resabs: a vertex may lie that far off a face's surface.
                    // Where one does (by more than 1e-9 m), the segment declares it as its tolerance, which
                    // the builder uses only where the face needs it; up to ten resabs, the file's own
                    // precision with a margin — past that, the build says where it fails.
                    {
                        const double resabs = file.resabs * place.scale * place.factor;
                        const auto off = [&](const Vector3& p) {
                            return surfaceDistance(shapeOf(patch.kind), patch.origin, patch.normal, patch.radius, patch.semiAngle,
                                                   patch.majorRadius, patch.minorRadius, p);
                        };
                        for (auto& loop : patch.loops)
                            for (auto& segment : loop) {
                                // A NURBS boundary may differ from its support between vertices.
                                // Its admissible gap is the SAT model's resabs too; the builder
                                // measures that gap instead of assuming its fixed 1e-7 precision.
                                if (patch.kind == kernel::AnalyticFacePatch::Kind::BSpline)
                                    segment.tolerance = std::max(segment.tolerance, resabs);
                                const double need = std::max({off(segment.start), off(segment.end), curveDistance(segment, segment.start),
                                                              curveDistance(segment, segment.end)});
                                if (need > 1e-9 && need <= 10.0 * resabs) segment.tolerance = std::max(segment.tolerance, 1.5 * need);
                            }
                    }
                    // The seam of a surface of revolution (where its angle starts) away from the face:
                    // ACIS's own start (a cone's major axis) often runs through it, and a loop across the seam
                    // cannot be trimmed as one piece. Only the parametrisation moves.
                    const bool explicitBoundary = std::any_of(patch.loops.begin(), patch.loops.end(), [](const auto& loop) {
                        return std::any_of(loop.begin(), loop.end(), [](const auto& segment) { return segment.pcurve.has_value(); });
                    });
                    if (!explicitBoundary && patch.kind != kernel::AnalyticFacePatch::Kind::Plane &&
                        patch.kind != kernel::AnalyticFacePatch::Kind::BSpline && patch.kind != kernel::AnalyticFacePatch::Kind::Blend) {
                        const Vector3& n = patch.normal;
                        Vector3 sum{0, 0, 0};
                        int count = 0;
                        for (const auto& loop : patch.loops)
                            for (const auto& segment : loop)
                                for (const Vector3& p : {segment.start, segment.end}) {
                                    Vector3 r{p.x - patch.origin.x, p.y - patch.origin.y, p.z - patch.origin.z};
                                    const double along = r.x * n.x + r.y * n.y + r.z * n.z;
                                    r = {r.x - along * n.x, r.y - along * n.y, r.z - along * n.z};
                                    const double length = norm(r);
                                    if (length < 1e-12) continue;
                                    sum = {sum.x + r.x / length, sum.y + r.y / length, sum.z + r.z / length};
                                    ++count;
                                }
                        if (count > 0 && norm(sum) > 0.1 * count)
                            patch.xAxis = {-sum.x / norm(sum), -sum.y / norm(sum), -sum.z / norm(sum)};
                    }
                    patches.push_back(std::move(patch));
                    patchFaces.push_back(face);
                    patchEdges.push_back(std::move(faceEdges));
                    face = nextFace;
                }
                shell = nextShell;
            }
            lumps.push_back({named, std::move(patches), std::move(patchFaces), std::move(patchEdges), std::move(approximations)});
            lump = nextLump;
        }
    }
    return true;
}

} // namespace

// SAB: the same records as SAT, each field a tag and its bytes. The header: 15 bytes of signature, four
// integers (version, records, entities, flags), then the product, ACIS version and date strings and the
// units, resabs and resnor as doubles.
bool tokenizeBinary(const QByteArray& bytes, SatFile& file, QString& error) {
    file.binary = true;
    const auto* data = reinterpret_cast<const uchar*>(bytes.constData());
    const std::size_t size = std::size_t(bytes.size());
    std::size_t at = 15;
    const auto integer = [&](std::size_t n) -> qint64 {
        quint64 v = 0;
        for (std::size_t i = 0; i < n && at + i < size; ++i) v |= quint64(data[at + i]) << (8 * i);
        at += n;
        if (n == 4) return qint32(quint32(v));
        if (n == 2) return qint16(quint16(v));
        return qint64(v);
    };
    const auto real = [&](std::size_t n) {
        double v = 0.0;
        if (n == 8 && at + 8 <= size) std::memcpy(&v, data + at, 8);
        if (n == 4 && at + 4 <= size) {
            float f = 0;
            std::memcpy(&f, data + at, 4);
            v = f;
        }
        at += n;
        return v;
    };
    if (size < 31) {
        error = QObject::tr("Двоичный файл ACIS обрезан.");
        return false;
    }
    file.version = int(integer(4));
    integer(4);
    integer(4);
    integer(4);
    // Header values: strings, then the doubles.
    std::vector<double> headerNumbers;
    bool inRecord = false;
    Record current;
    std::string pending; // an identifier's leading parts, each followed by '-'
    bool ended = false;
    while (at < size && !ended) {
        const uchar tag = data[at++];
        Token token;
        bool keep = true;
        switch (tag) {
        case 2: token = {Token::Kind::Number, double(integer(1))}; break;
        case 3: token = {Token::Kind::Number, double(integer(2))}; break;
        case 4: token = {Token::Kind::Number, double(integer(4))}; break;
        case 5: token = {Token::Kind::Number, real(4)}; break;
        case 6: token = {Token::Kind::Number, real(8)}; break;
        case 7: case 8: case 9: case 18: {
            const std::size_t length = std::size_t(integer(tag == 7 ? 1 : tag == 8 ? 2 : 4));
            if (at + length > size) return error = QObject::tr("Строка в двоичном файле ACIS обрезана."), false;
            token = {Token::Kind::String, 0.0, std::string(reinterpret_cast<const char*>(data + at), length)};
            at += length;
            break;
        }
        case 10: token = {Token::Kind::Word, 0.0, "T"}; break;
        case 11: token = {Token::Kind::Word, 0.0, "I"}; break;
        case 12: token = {Token::Kind::Pointer, double(integer(4))}; break;
        case 13: case 14: {
            const std::size_t length = std::size_t(integer(1));
            if (at + length > size) return error = QObject::tr("Имя в двоичном файле ACIS обрезано."), false;
            const std::string part(reinterpret_cast<const char*>(data + at), length);
            at += length;
            if (tag == 14) {
                pending += part + "-";
                keep = false;
                break;
            }
            const std::string name = pending + part;
            pending.clear();
            if (!inRecord) {
                if (name.rfind("End-of-", 0) == 0 || name.rfind("Begin-of-", 0) == 0) {
                    ended = true;
                    keep = false;
                    break;
                }
                current = {};
                current.type = name;
                inRecord = true;
                keep = false;
                break;
            }
            token = {Token::Kind::Word, 0.0, name};
            break;
        }
        case 15: token = {Token::Kind::Open}; break;
        case 16: token = {Token::Kind::Close}; break;
        case 17:
            if (inRecord) {
                current.index = static_cast<long long>(file.records.size());
                file.byIndex[current.index] = file.records.size();
                file.records.push_back(std::move(current));
                current = {};
                inRecord = false;
            }
            keep = false;
            break;
        case 19: case 20:
            for (int i = 0; i < 3; ++i) {
                const Token coordinate{Token::Kind::Number, real(8)};
                if (inRecord) current.data.push_back(coordinate);
            }
            keep = false;
            break;
        case 21: token = {Token::Kind::Word, 0.0, "E" + std::to_string(integer(4))}; break;
        case 22:
            for (int i = 0; i < 2; ++i) {
                const Token coordinate{Token::Kind::Number, real(8)};
                if (inRecord) current.data.push_back(coordinate);
            }
            keep = false;
            break;
        case 23: token = {Token::Kind::Number, real(8)}; break;
        default:
            error = QObject::tr("Двоичный файл ACIS: неизвестная метка %1 на байте %2.").arg(tag).arg(at - 1);
            return false;
        }
        if (!keep) continue;
        if (inRecord) current.data.push_back(std::move(token));
        else if (token.kind == Token::Kind::Number) headerNumbers.push_back(token.value);
    }
    if (!ended) {
        error = QObject::tr("Двоичный файл ACIS не доходит до своего конца (End-of-…-data).");
        return false;
    }
    if (!headerNumbers.empty() && headerNumbers[0] > 0.0) file.millimetresPerUnit = headerNumbers[0];
    if (headerNumbers.size() > 1 && headerNumbers[1] > 0.0 && headerNumbers[1] < 1e-2) file.resabs = headerNumbers[1];
    if (file.records.empty()) {
        error = QObject::tr("В файле ACIS нет записей.");
        return false;
    }
    for (std::size_t r = 0; r < file.records.size(); ++r) {
        const auto& d = file.records[r].data;
        for (std::size_t i = 0; i + 1 < d.size(); ++i)
            if (d[i].kind == Token::Kind::Open && !(d[i + 1].kind == Token::Kind::Word && d[i + 1].text == "ref"))
                file.subtypes.push_back({r, i});
    }
    // The fields before a class's own: a body's own are its last three pointers (lump, wire, transform).
    for (const Record& record : file.records)
        if (record.type == "body" && record.data.size() >= 4) {
            file.header = int(record.data.size()) - 3;
            break;
        }
    file.geometryHeader = file.header;
    return true;
}

bool readAcisSat(const QByteArray& text, kernel::OcctKernel& kernel, AcisSatResult& result, QString& error,
                 ParasolidXtBuildReport* report, const QString& name, double millimetresPerUnit) {
    SatFile file;
    const bool binary = text.startsWith("ACIS BinaryFile") || text.startsWith("ASM BinaryFile");
    if (!(binary ? tokenizeBinary(text, file, error) : tokenize(text, file, error))) return false;
    result.version = file.version;
    result.millimetresPerUnit = file.millimetresPerUnit;
    // Units the file does not state are taken as millimetres. The solid is built as if a unit were a
    // metre all the same — well clear of the builder's absolute tolerances (1e-7 m) whatever the file's
    // size — and scaled down after: read at 1 mm a unit, a part written in metres (all the 1.0x files of
    // the samples) came out 0.05 mm across, its edges shorter than those tolerances.
    Placement units;
    double afterwards = 1.0;
    if (file.millimetresPerUnit > 0.0) {
        units.scale = 1.0;
        afterwards = file.millimetresPerUnit * 1e-3;
    } else if (millimetresPerUnit > 0.0) {
        units.scale = 1.0;
        afterwards = millimetresPerUnit * 1e-3;
        result.millimetresPerUnit = millimetresPerUnit;
    } else {
        units.scale = 1.0;
        afterwards = 1e-3;
        result.notes << QObject::tr("Единицы в файле ACIS не указаны — прочитано в миллиметрах");
    }

    // A legitimate sliver may be smaller than OCCT's absolute construction precision
    // even in the original units (old SATs in metres contain edges only 15 nm long).
    // Normalize the build, then undo that scale together with the unit conversion.
    // No vertex, edge or face is discarded to make the shell pass validation.
    double shortest = std::numeric_limits<double>::infinity();
    for (const Record& record : file.records) {
        if (record.type != "edge") continue;
        Edge edge;
        Vector3 a, b;
        if (!edgeRecord(file, record, edge) || edge.start == edge.end ||
            !vertexPoint(file, edge.start, units, a) || !vertexPoint(file, edge.end, units, b)) continue;
        const double chord = norm(subtract(a, b));
        if (chord > 0.0 && std::isfinite(chord)) shortest = std::min(shortest, chord);
    }
    if (shortest < 1e-6) {
        const double scale = std::min(1e6, std::pow(10.0, std::ceil(std::log10(1e-6 / shortest))));
        units.scale *= scale;
        afterwards /= scale;
    }

    std::vector<LumpPatches> lumps;
    if (!collectLumps(file, units, lumps, result.notes, error)) return false;
    int approximatedEdges = 0;
    double largestFit = 0.0;
    for (LumpPatches& lump : lumps) {
        const auto& patchFaces = lump.faces;
        kernel::AnalyticSolidReport built;
        auto solid = kernel.makeAnalyticSolid(lump.patches, &built);
        // An intersection OCCT cannot follow exactly (two surfaces nearly tangent along it: a small hole
        // grazing a bore's wall) fails its face. That face's intersection edges — wherever they occur —
        // are then taken as the file has them, its approximation within its fit tolerance, and the
        // body built again; exact everywhere else.
        std::set<long long> approximated;
        while (!solid.isOk() && built.failedPatch < lump.patches.size()) {
            std::vector<long long> exact;
            const auto& failedEdges = lump.edges[built.failedPatch];
            for (std::size_t l = 0; l < failedEdges.size(); ++l)
                for (std::size_t s = 0; s < failedEdges[l].size(); ++s)
                    if (lump.patches[built.failedPatch].loops[l][s].kind == kernel::AnalyticEdgeKind::SurfaceIntersection)
                        exact.push_back(failedEdges[l][s]);
            if (exact.empty()) break;
            for (const long long edge : exact) {
                const auto& [approximation, fit] = lump.approximations.at(edge);
                for (std::size_t p = 0; p < lump.patches.size(); ++p)
                    for (std::size_t l = 0; l < lump.edges[p].size(); ++l)
                        for (std::size_t s = 0; s < lump.edges[p][l].size(); ++s) {
                            if (lump.edges[p][l][s] != edge) continue;
                            auto& segment = lump.patches[p].loops[l][s];
                            segment.kind = kernel::AnalyticEdgeKind::BSpline;
                            segment.bspline = approximation;
                            // Its ends are the vertices, within the fit of the curve.
                            double gap = 0.0;
                            for (const Vector3& end : {segment.start, segment.end}) {
                                const Vector3 q = evaluate(approximation, nearestParameter(approximation, end));
                                gap = std::max(gap, norm({q.x - end.x, q.y - end.y, q.z - end.z}));
                            }
                            segment.tolerance = std::max({segment.tolerance, 1.5 * fit, 1.5 * gap, 1e-7});
                        }
                approximated.insert(edge);
                largestFit = std::max(largestFit, fit);
            }
            solid = kernel.makeAnalyticSolid(lump.patches, &built);
        }
        approximatedEdges += int(approximated.size());
        if (!solid.isOk()) {
            error = QObject::tr("Грани ACIS не образуют проверенное тело (грань ACIS %1): %2")
                        .arg(built.failedPatch<patchFaces.size()?patchFaces[built.failedPatch]:-1)
                        .arg(QString::fromStdString(solid.error().message));
            return false;
        }
        kernel::ShapeHandle shape = solid.value();
#ifdef CADNEXT_WITH_OCCT
        if (afterwards != 1.0) {
            try {
                gp_Trsf scaling;
                scaling.SetScale(gp::Origin(), afterwards);
                BRepBuilderAPI_Transform scaled(*kernel.findShape(shape), scaling, true);
                if (!scaled.IsDone()) throw Standard_Failure("not done");
                shape = kernel.adoptShape(scaled.Shape(), "acis-sat");
            } catch (const Standard_Failure&) {
                error = QObject::tr("Тело ACIS не удалось привести к миллиметрам.");
                return false;
            }
        }
#endif
        QString label = lump.name.isEmpty() ? name : lump.name;
        if (label.isEmpty()) label = QObject::tr("Тело ACIS");
        result.solids.push_back({label, shape});
        if (report) {
            // In metres: the build's units scaled as the solid was.
            for (const auto& face : built.approximated)
                report->approximated.push_back({quint32(face.patchIndex < patchFaces.size() ? patchFaces[face.patchIndex] : 0),
                                                face.deviation * afterwards, face.contactGap * afterwards});
            report->largestEdgeTolerance = std::max(report->largestEdgeTolerance, built.largestEdgeTolerance * afterwards);
            for (const auto& split : built.split)
                report->split.push_back({quint32(split.patchIndex < patchFaces.size() ? patchFaces[split.patchIndex] : 0),
                                         split.faces, {}});
        }
    }
    if (approximatedEdges > 0)
        result.notes << QObject::tr("Рёбер пересечения по аппроксимации из файла: %1 (до %2 мм от точных; поверхности касаются вдоль них)")
                            .arg(approximatedEdges)
                            .arg(largestFit * afterwards * 1e3, 0, 'g', 2);
    if (result.solids.empty()) {
        error = QObject::tr("В файле ACIS нет твёрдых тел.");
        return false;
    }
    std::map<QString, int> counts, occurrences;
    for (const auto& solid : result.solids) ++counts[solid.name];
    for (auto& solid : result.solids) if (counts[solid.name] > 1) {
        const int occurrence = ++occurrences[solid.name];
        solid.name += QObject::tr(" (%1)").arg(occurrence);
    }
    return true;
}

bool readAcisSatFile(const QString& path, kernel::OcctKernel& kernel, AcisSatResult& result, QString& error,
                     ParasolidXtBuildReport* report) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        error = QObject::tr("Не удалось открыть %1.").arg(path);
        return false;
    }
    return readAcisSat(file.readAll(), kernel, result, error, report, QFileInfo(path).completeBaseName());
}

} // namespace cadnext::gui
