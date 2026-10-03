#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeKompasStorage.hpp"
#include "cadnext/gui/NativeKompasCatalog.hpp"
#include "cadnext/gui/NativeKompasTopology.hpp"
#include "cadnext/gui/NativeKompasBodyApplication.hpp"
#include "cadnext/gui/NativeKompasOperation.hpp"
#include "cadnext/gui/NativeKompasModel.hpp"
#include "cadnext/gui/NativeKompasProperties.hpp"
#include "cadnext/gui/NativeKompasDocument.hpp"
#include "../gui/src/NativeKompasUvCurve.hpp"

#include <QByteArray>
#include <QFile>
#include <QTemporaryDir>
#include <QString>

#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

#include <zlib.h>

namespace {

QByteArray deflate(const QByteArray& data) {
    uLongf size = compressBound(static_cast<uLong>(data.size()));
    QByteArray compressed(qsizetype(size), Qt::Uninitialized);
    const int status = compress2(reinterpret_cast<Bytef*>(compressed.data()), &size,
                                 reinterpret_cast<const Bytef*>(data.constData()),
                                 static_cast<uLong>(data.size()), Z_BEST_COMPRESSION);
    assert(status == Z_OK);
    compressed.resize(qsizetype(size));
    return compressed;
}

quint16 zipU16(const QByteArray& bytes, qsizetype at) {
    return quint16(quint8(bytes.at(at))) |
           (quint16(quint8(bytes.at(at + 1))) << 8);
}

quint32 zipU32(const QByteArray& bytes, qsizetype at) {
    return quint32(zipU16(bytes, at)) | (quint32(zipU16(bytes, at + 2)) << 16);
}

QByteArray storedZipMember(const QByteArray& archive, const QByteArray& wanted) {
    for (qsizetype at = 0; at + 30 <= archive.size();) {
        if (zipU32(archive, at) != 0x04034b50) return {};
        const qsizetype nameSize = zipU16(archive, at + 26);
        const qsizetype extraSize = zipU16(archive, at + 28);
        const qsizetype dataAt = at + 30 + nameSize + extraSize;
        const qsizetype size = qsizetype(zipU32(archive, at + 18));
        if (nameSize <= 0 || dataAt < at || dataAt > archive.size() ||
            size < 0 || size > archive.size() - dataAt)
            return {};
        if (archive.mid(at + 30, nameSize) == wanted)
            return archive.mid(dataAt, size);
        at = dataAt + size;
    }
    return {};
}

} // namespace

int main() {
    using namespace cadnext::gui;
    {
        // Independent file-link definition with object ID zero.
        const auto fixture=QByteArray::fromHex(
            "010100000000000000028021480100000101000000780000000000"
            "7856341200000000040000000000000000");
        QString error;QByteArray encoded;std::vector<KompasDocumentFileLink> links;
        assert(decodeKompasDocumentFileLinks(fixture,links,error) && links.size()==1);
        assert(links[0].objectId==0 && links[0].relativePath=="x" && links[0].absolutePath.isEmpty());
        assert(links[0].nativeMark==0x12345678);
        assert(encodeKompasDocumentFileLinks(links,encoded,error) && encoded==fixture);
        for(qsizetype end=0;end<fixture.size();++end) {
            auto output=links;
            assert(!decodeKompasDocumentFileLinks(fixture.left(end),output,error));
            assert(output.empty() && !error.isEmpty());
        }
        for(const qsizetype at:{qsizetype(0),qsizetype(9),qsizetype(10),qsizetype(11),qsizetype(13),
                                qsizetype(16),qsizetype(17),qsizetype(31),qsizetype(35),qsizetype(43)}) {
            auto corrupt=fixture;corrupt[at]=char(uchar(corrupt[at])^0x80);
            assert(!decodeKompasDocumentFileLinks(corrupt,links,error) && links.empty());
        }
        assert(!decodeKompasDocumentFileLinks(fixture+QByteArray("tail"),links,error));
        assert(decodeKompasDocumentFileLinks(fixture,links,error));
        auto second=links[0];second.objectId=65535;second.nativeMark=0;
        second.relativePath=QString::fromUtf8("узлы/деталь.m3d");second.absolutePath="";
        links.push_back(second);
        assert(encodeKompasDocumentFileLinks(links,encoded,error));
        std::vector<KompasDocumentFileLink> decoded;
        assert(decodeKompasDocumentFileLinks(encoded,decoded,error));
        assert(decoded.size()==2 && decoded[1].objectId==65535 && decoded[1].relativePath==second.relativePath);
        assert(decoded[1].nativeMark && *decoded[1].nativeMark==0);
        QByteArray repeated;
        assert(encodeKompasDocumentFileLinks(decoded,repeated,error) && repeated==encoded);
        for(int change=0;change<5;++change) {
            auto bad=links;
            if(change==0)bad[1].objectId=0;
            if(change==1)bad[1].nativeMark.reset();
            if(change==2){bad[1].relativePath.clear();bad[1].absolutePath.clear();}
            if(change==3)bad[1].relativePath=QString(65537,u'x');
            if(change==4)bad[1].absolutePath=QString(65537,u'x');
            encoded="stale";
            assert(!encodeKompasDocumentFileLinks(bad,encoded,error) && encoded.isEmpty());
        }
        assert(encodeKompasDocumentFileLinks({},encoded,error));
        assert(encoded==QByteArray::fromHex("010000000000000000"));
        assert(decodeKompasDocumentFileLinks(encoded,decoded,error) && decoded.empty());
    }
    {
        // Independently authored default-profile document settings, with
        // arbitrary style names/colors. No native document template is used.
        const auto prefix=QByteArray::fromHex(
            "010000004400fca9f1d24d62b03f000000000000d83fff0f040000"
            "01000000000000000001030000000101012d000200000001000000"
            "0101012e0002000000010000000100000100000001000000000101010100000000"
            "dc000000");
        const auto styleBytes=QByteArray::fromHex("01000000530056341200141e28323c460100");
        auto fixture=prefix;
        for(int i=0;i<220;++i)fixture+=styleBytes;
        QString error;QByteArray encoded;KompasDocumentSettings settings;
        assert(decodeKompasDocumentSettings(fixture,settings,error));
        assert(settings.title=="D" && !settings.assembly && settings.styles.size()==220);
        assert(settings.styles[0].name=="S" && settings.styles[219].color==0x123456);
        assert((settings.styles[219].material==std::array<quint8,6>{20,30,40,50,60,70}));
        assert(settings.styles[0].nativeFlags[0] && !settings.styles[0].nativeFlags[1]);
        assert(encodeKompasDocumentSettings(settings,encoded,error) && encoded==fixture);
        for(qsizetype end=0;end<fixture.size();++end) {
            auto output=settings;
            assert(!decodeKompasDocumentSettings(fixture.left(end),output,error));
            assert(output.title.isEmpty() && output.styles.empty() && !error.isEmpty());
        }
        // Scalar profile, assembly flag, formatting fields and table count.
        for(const qsizetype at:{qsizetype(6),qsizetype(22),qsizetype(26),qsizetype(27),
                                qsizetype(36),qsizetype(44),qsizetype(70),qsizetype(87)}) {
            auto corrupt=fixture;corrupt[at]=char(uchar(corrupt[at])^0x80);
            assert(!decodeKompasDocumentSettings(corrupt,settings,error) && settings.styles.empty());
        }
        for(const qsizetype at:{prefix.size()+9,prefix.size()+10,prefix.size()+16,prefix.size()+17}) {
            auto corrupt=fixture;corrupt[at]=char(0xff);
            assert(!decodeKompasDocumentSettings(corrupt,settings,error) && settings.styles.empty());
        }
        assert(!decodeKompasDocumentSettings(fixture+QByteArray("tail"),settings,error));
        assert(decodeKompasDocumentSettings(fixture,settings,error));
        settings.assembly=true;settings.title=QString::fromUtf8("Два тела");
        settings.styles[219].name=QString::fromUtf8("Собственный стиль");
        settings.styles[0].nativeFlags={false,true};
        assert(encodeKompasDocumentSettings(settings,encoded,error));
        KompasDocumentSettings decoded;
        assert(decodeKompasDocumentSettings(encoded,decoded,error));
        assert(decoded.assembly && decoded.title==settings.title);
        assert(decoded.styles[219].name==settings.styles[219].name);
        assert(decoded.styles[0].nativeFlags==settings.styles[0].nativeFlags);
        QByteArray repeated;
        assert(encodeKompasDocumentSettings(decoded,repeated,error) && repeated==encoded);
        for(int change=0;change<6;++change) {
            auto bad=settings;
            if(change==0)bad.styles.pop_back();
            if(change==1)bad.styles.emplace_back();
            if(change==2)bad.styles[0].color=0x1000000;
            if(change==3)bad.styles[1].material[5]=101;
            if(change==4)bad.title=QString(65537,u'x');
            if(change==5)bad.styles[219].name=QString(65537,u'x');
            encoded="stale";
            assert(!encodeKompasDocumentSettings(bad,encoded,error) && encoded.isEmpty());
        }
    }
    {
        // Independent inline property, ID 100, with short arbitrary labels.
        const auto fixture=QByteArray::fromHex(
            "010100000000000000010100437300000000020000000000000000000000"
            "0000000000407040000000000000594001000000580001000000590004000000"
            "010000004e00000004000000020000000000000000000800000000000000"
            "010000000000000000");
        QString error;QByteArray encoded;KompasPropertyDefinitions definitions;
        assert(decodeKompasPropertyDefinitions(fixture,definitions,error));
        assert(definitions.entries.size()==1);
        const auto& property=definitions.entries.front();
        assert(property.id==100 && property.nativeType==2 && property.nativeLimit==260);
        assert(property.sourceKey=="X" && property.valueKey=="Y" && property.displayName=="N");
        assert(!property.choices && property.nativeRule==2);
        assert(encodeKompasPropertyDefinitions(definitions,encoded,error) && encoded==fixture);
        for(qsizetype end=0;end<fixture.size();++end) {
            auto output=definitions;
            assert(!decodeKompasPropertyDefinitions(fixture.left(end),output,error));
            assert(output.entries.empty() && !error.isEmpty());
        }
        for(const qsizetype at:{qsizetype(0),qsizetype(9),qsizetype(10),qsizetype(11),qsizetype(12),
                                qsizetype(14),qsizetype(26),fixture.size()-9}) {
            auto corrupt=fixture;corrupt[at]=char(uchar(corrupt[at])^0x80);
            assert(!decodeKompasPropertyDefinitions(corrupt,definitions,error) && definitions.entries.empty());
        }
        assert(!decodeKompasPropertyDefinitions(fixture+QByteArray("tail"),definitions,error));
        assert(decodeKompasPropertyDefinitions(fixture,definitions,error));
        auto second=definitions.entries.front();second.id=37;second.nativeType=1;
        second.nativeLimit=1e9;second.sourceKey=QString::fromUtf8("ключ");
        second.displayName=QString::fromUtf8("Профиль");second.choices=std::vector<QString>{QString::fromUtf8("Да"),"No"};
        definitions.entries.push_back(second);
        assert(encodeKompasPropertyDefinitions(definitions,encoded,error));
        KompasPropertyDefinitions decoded;
        assert(decodeKompasPropertyDefinitions(encoded,decoded,error));
        assert(decoded.entries[1].displayName==second.displayName && decoded.entries[1].choices==second.choices);
        QByteArray repeated;
        assert(encodeKompasPropertyDefinitions(decoded,repeated,error) && repeated==encoded);
        definitions.entries[1].choices=std::vector<QString>{};
        assert(encodeKompasPropertyDefinitions(definitions,encoded,error));
        assert(decodeKompasPropertyDefinitions(encoded,decoded,error));
        assert(decoded.entries[1].choices && decoded.entries[1].choices->empty());
        for(int change=0;change<8;++change) {
            auto bad=definitions;
            if(change==0)bad.entries[1].id=100;
            if(change==1)bad.entries[1].id=0;
            if(change==2)bad.entries[1].id=std::numeric_limits<double>::quiet_NaN();
            if(change==3)bad.entries[1].nativeType=3;
            if(change==4)bad.entries[1].nativeRule=4;
            if(change==5)bad.entries[1].nativeLimit=-1;
            if(change==6)bad.entries[1].valueKey=QString(65537,u'x');
            if(change==7)bad.entries[1].choices=std::vector<QString>{QString(65537,u'x')};
            encoded="stale";
            assert(!encodeKompasPropertyDefinitions(bad,encoded,error) && encoded.isEmpty());
        }
        const auto tuningFixture=QByteArray::fromHex(
            "0200000000000000000000000000594001000000000080424000"
            "0100000000000000000000000080424001");
        KompasPropertyTuning tuning;
        assert(decodeKompasPropertyTuning(tuningFixture,tuning,error));
        assert(tuning.lists[0].size()==2 && tuning.lists[1].size()==1);
        assert(tuning.lists[0][0].id==100 && tuning.lists[0][0].enabled);
        assert(tuning.lists[0][1].id==37 && !tuning.lists[0][1].enabled);
        assert(tuning.lists[1][0].id==37 && tuning.lists[1][0].enabled);
        assert(encodeKompasPropertyTuning(tuning,encoded,error) && encoded==tuningFixture);
        assert(validateKompasPropertyReferences(definitions,tuning,error));
        definitions.entries.pop_back();
        assert(!validateKompasPropertyReferences(definitions,tuning,error));
        for(qsizetype end=0;end<tuningFixture.size();++end) {
            auto output=tuning;
            assert(!decodeKompasPropertyTuning(tuningFixture.left(end),output,error));
            assert(output.lists[0].empty() && output.lists[1].empty());
        }
        auto corrupt=tuningFixture;corrupt[16]=2;
        assert(!decodeKompasPropertyTuning(corrupt,tuning,error));
        assert(!decodeKompasPropertyTuning(tuningFixture+QByteArray("tail"),tuning,error));
        assert(decodeKompasPropertyTuning(tuningFixture,tuning,error));
        auto bad=tuning;bad.lists[0].push_back(bad.lists[0][0]);encoded="stale";
        assert(!encodeKompasPropertyTuning(bad,encoded,error) && encoded.isEmpty());
        bad=tuning;bad.lists[1][0].id=std::numeric_limits<double>::infinity();
        assert(!encodeKompasPropertyTuning(bad,encoded,error) && encoded.isEmpty());
        assert(encodeKompasPropertyDefinitions({},encoded,error));
        assert(encoded==QByteArray::fromHex("010000000000000000010000000000000000"));
        assert(encodeKompasPropertyTuning({},encoded,error) && encoded==QByteArray(16,'\0'));
    }
    {
        // An independently specified rational quadratic quarter circle.
        // Its midpoint and tangent have closed forms, without a CAD fixture.
        const auto fixture=QByteArray::fromHex(
            "0200000000000000000000000000f03f0000000000000000000000000000f03f000000000000f03f0000000000000000"
            "000000000000f03f000000000000f0bf9c7500883ce4377e9c7500883ce4377e9c7500883ce437fe9c7500883ce437fe"
            "00030000000000000005000000000000000000000000000000f03fcd3b7f669ea0e63f000000000000f03f000000000000"
            "000000000000000000000000000000000000000000000000f03f000000000000f03f000000000000f03f");
        detail::KompasNurbs2 curve;QString error;qsizetype consumed=0;QByteArray bytes;
        assert(fixture.size()==187);
        assert(detail::decodeKompasNurbs2Data(fixture,0,curve,consumed,error));
        assert(consumed==fixture.size() && curve.order==3 && !curve.closed);
        assert(detail::encodeKompasNurbs2Data(curve,bytes,error) && bytes==fixture);
        const double w=std::sqrt(.5);
        const auto middle=detail::pointOnKompasNurbs2(curve,.5);
        const auto tangent=detail::derivativeOnKompasNurbs2(curve,.5);
        assert(std::fabs(middle[0]-w)<1e-15 && std::fabs(middle[1]-w)<1e-15);
        assert(std::fabs(tangent[0]+2/(1+w))<1e-14 && std::fabs(tangent[1]-2/(1+w))<1e-14);
        for(int i=0;i<=64;++i) {
            const auto point=detail::pointOnKompasNurbs2(curve,i/64.0);
            assert(std::fabs(point[0]*point[0]+point[1]*point[1]-1)<1e-14);
        }
        const auto clipped=detail::restrictKompasNurbs2(curve,.125,.875);
        for(int i=0;i<=64;++i) {
            const double t=.125+.75*i/64;
            const auto a=detail::pointOnKompasNurbs2(curve,t),b=detail::pointOnKompasNurbs2(clipped,t);
            const auto da=detail::derivativeOnKompasNurbs2(curve,t),db=detail::derivativeOnKompasNurbs2(clipped,t);
            for(int k=0;k<2;++k)assert(std::fabs(a[k]-b[k])<1e-14 && std::fabs(da[k]-db[k])<1e-13);
        }
        for(qsizetype end=0;end<fixture.size();++end) {
            auto decoded=curve;consumed=123;
            assert(!detail::decodeKompasNurbs2Data(fixture.left(end),0,decoded,consumed,error));
            assert(decoded.poles.empty() && consumed==0);
        }
        for(int change=0;change<7;++change) {
            auto bad=curve;
            if(change==0)bad.weights[1]=0;
            if(change==1)bad.poles[0][0]=std::numeric_limits<double>::infinity();
            if(change==2)bad.knots[3]=-.5;
            if(change==3)bad.knots[3]=0;
            if(change==4)bad.order=27;
            if(change==5)bad.nativeFlags[1]=1;
            if(change==6)bad.cache[3]=-1;
            bytes="stale";
            assert(!detail::encodeKompasNurbs2Data(bad,bytes,error) && bytes.isEmpty());
        }
        detail::KompasNurbs2 closed;
        closed.poles={{{1,0}},{{0,1}},{{-1,0}},{{0,-1}}};closed.weights={1,1,1,1};
        closed.order=3;closed.closed=true;closed.knots={-2,-1,0,1,2,3,4,5,6};
        assert(detail::encodeKompasNurbs2Data(closed,bytes,error));
        detail::KompasNurbs2 decoded;
        assert(detail::decodeKompasNurbs2Data(bytes,0,decoded,consumed,error) && decoded.closed);
        for(const double t:{0.,4.}) {
            const auto p=detail::pointOnKompasNurbs2(decoded,t);
            assert(p[0]==.5 && p[1]==.5);
        }
        for(const auto range:{std::array<double,2>{.3,3.7},std::array<double,2>{0,4}}) {
            const auto portion=detail::restrictKompasNurbs2(decoded,range[0],range[1]);
            for(int i=0;i<=64;++i) {
                const double t=range[0]+(range[1]-range[0])*i/64;
                const auto a=detail::pointOnKompasNurbs2(decoded,t),b=detail::pointOnKompasNurbs2(portion,t);
                const auto da=detail::derivativeOnKompasNurbs2(decoded,t),db=detail::derivativeOnKompasNurbs2(portion,t);
                for(int k=0;k<2;++k)assert(std::fabs(a[k]-b[k])<1e-14 && std::fabs(da[k]-db[k])<1e-13);
            }
        }
        detail::KompasNurbs2 degreeFive;degreeFive.order=6;
        degreeFive.knots={3,3,3,3,3,3,7,7,7,7,7,7};
        double numerator=0,denominator=0;
        const int binomial[6]={1,5,10,10,5,1};
        for(int i=0;i<6;++i) {
            degreeFive.poles.push_back({double(i),double(i*i)});degreeFive.weights.push_back(i+1);
            numerator+=binomial[i]*(i+1)*i*i;denominator+=binomial[i]*(i+1);
        }
        assert(std::fabs(detail::pointOnKompasNurbs2(degreeFive,5)[1]-numerator/denominator)<1e-14);
        detail::KompasUvCurve uv;uv.kind=detail::KompasUvCurve::Nurbs;uv.nurbs=degreeFive;uv.first=3;uv.last=7;
        detail::normalizeKompasUvPolynomial(uv);
        for(int i=0;i<=64;++i) {
            const double t=i/64.0;
            const auto a=detail::pointOnKompasNurbs2(degreeFive,3+4*t),b=detail::kompasUvPoint(uv,t);
            const auto da=detail::derivativeOnKompasNurbs2(degreeFive,3+4*t),db=detail::kompasUvDerivative(uv,t);
            for(int k=0;k<2;++k)assert(std::fabs(a[k]-b[k])<1e-14 && std::fabs(4*da[k]-db[k])<1e-13);
        }
        // A paired boundary whose domain differs only by rounding should
        // keep the original nonzero interval, rather than forcing both to 0..1.
        detail::normalizeKompasUvPolynomial(uv,7,3);
        for(int i=0;i<=64;++i) {
            const double t=3+4*i/64.;
            const auto a=detail::pointOnKompasNurbs2(degreeFive,t),b=detail::kompasUvPoint(uv,t);
            const auto da=detail::derivativeOnKompasNurbs2(degreeFive,t),db=detail::kompasUvDerivative(uv,t);
            for(int k=0;k<2;++k)assert(std::fabs(a[k]-b[k])<1e-14 && std::fabs(da[k]-db[k])<1e-13);
        }
    }
    {
        // Independently laid out deferred cache: quantities are zero, the
        // centre and final metric carry the native "not calculated" sentinels.
        QByteArray fixture(466,char(0));
        fixture.replace(1,8,QByteArray::fromHex("aed85f764f1e663f")); // .0027 g/mm^3
        fixture[9]=1;fixture[13]=1;
        for(const auto offset:{38,46,54})
            fixture.replace(offset,8,QByteArray::fromHex("7cdb41bb487f95dc")); // -1e138
        fixture.replace(458,8,QByteArray::fromHex("3049ce95a03261dc")); // -1e137
        KompasDeferredMassProperties cache;QString error;qsizetype consumed=0;QByteArray encoded;
        assert(decodeKompasDeferredMassProperties(fixture,0,cache,consumed,error));
        assert(consumed==466 && cache.nativeDensity==.0027);
        assert(encodeKompasDeferredMassProperties(cache,encoded,error) && encoded==fixture);
        for(qsizetype end=0;end<fixture.size();++end) {
            cache.nativeDensity=99;consumed=123;
            assert(!decodeKompasDeferredMassProperties(fixture.left(end),0,cache,consumed,error));
            assert(consumed==0 && cache.nativeDensity==KompasDeferredMassProperties{}.nativeDensity);
        }
        for(const auto offset:{0,9,13,14,22,26,34,38,62,66,74,78,146,150,178,190,454,458}) {
            auto corrupt=fixture;corrupt[offset]=char(uchar(corrupt[offset])^1);
            assert(!decodeKompasDeferredMassProperties(corrupt,0,cache,consumed,error));
        }
        for(const auto density:{-1.,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
            cache.nativeDensity=density;encoded="stale";
            assert(!encodeKompasDeferredMassProperties(cache,encoded,error) && encoded.isEmpty());
        }
        assert(!decodeKompasDeferredMassProperties(fixture,-1,cache,consumed,error));

        const auto display=QByteArray::fromHex(
            "00000000000000000000000000000000000000004040000034420000000000000000000000000000000000000000"
            "000000ff010000000000000000000000000000000000");
        const auto bodyFixture=QByteArray::fromHex(
            "0103000000040000005000610072007400563412000a141e28323c01003259")+fixture+
            QByteArray::fromHex("010000004d009a99999999990540")+display+
            QByteArray::fromHex("2d00000000002e0000000000200000000000");
        KompasBodyProperties body;
        assert(bodyFixture.size()==597);
        assert(decodeKompasBodyProperties(bodyFixture+QByteArray("tail"),0,body,consumed,error));
        assert(consumed==597 && body.properties.name=="Part" && body.properties.materialName=="M");
        assert(body.properties.color==0x123456 && body.massCache.nativeDensity==.0027);
        assert(encodeKompasBodyProperties(body,encoded,error) && encoded==bodyFixture);
        for(qsizetype end=0;end<bodyFixture.size();++end) {
            body.properties.name="stale";consumed=123;
            assert(!decodeKompasBodyProperties(bodyFixture.left(end),0,body,consumed,error));
            assert(consumed==0 && body.properties.name.isEmpty());
        }
        assert(decodeKompasBodyProperties(bodyFixture,0,body,consumed,error));
        body.nativeFlags=0;body.properties.name=QString::fromUtf8("Тело 🛠");
        assert(encodeKompasBodyProperties(body,encoded,error));
        KompasBodyProperties restored;
        assert(decodeKompasBodyProperties(encoded,0,restored,consumed,error));
        assert(restored.nativeFlags==0 && restored.properties.name==body.properties.name);
        for(int change=0;change<4;++change) {
            auto bad=body;
            if(change==0)bad.nativeFlags=1;
            if(change==1)bad.properties.color=0x1000000;
            if(change==2)bad.massCache.nativeDensity=.004;
            if(change==3)bad.properties.name=QString(65537,QChar('x'));
            encoded="stale";
            assert(!encodeKompasBodyProperties(bad,encoded,error) && encoded.isEmpty());
        }
    }
    {
        // Independent property record with custom color, material and density.
        const auto fixture=QByteArray::fromHex(
            "000000000400000050006100720074002d00000000002e0000000000200000000000563412000a141e28323c01000000"
            "4d009a999999999905400000000000000000000000000000000000000000404000003442000000000000000000000000"
            "0000000000000000000000ff010000000000000000000000000000000000");
        QString error;qsizetype consumed=0;QByteArray encoded;KompasModelProperties properties;
        assert(decodeKompasModelProperties(fixture,0,properties,consumed,error));
        assert(consumed==126 && properties.name=="Part" && properties.materialName=="M");
        assert(properties.color==0x123456 && properties.nativeDensity==2.7);
        assert((properties.material==std::array<quint8,6>{10,20,30,40,50,60}));
        assert(encodeKompasModelProperties(properties,encoded,error) && encoded==fixture);
        for(qsizetype end=0;end<fixture.size();++end) {
            properties.name="old";consumed=123;
            assert(!decodeKompasModelProperties(fixture.left(end),0,properties,consumed,error));
            assert(consumed==0 && properties.name.isEmpty() && properties.materialName.isEmpty());
        }
        for(const auto offset:{0,4,16,18,22,26,32,37,38,44,57,74,76,80,105,107,108,125}) {
            auto corrupt=fixture;corrupt[offset]=char(uchar(corrupt[offset])^0x80);
            assert(!decodeKompasModelProperties(corrupt,0,properties,consumed,error));
        }
        properties.name=QString::fromUtf8("Деталь 🛠");properties.materialName=QString::fromUtf8("Сплав");
        assert(encodeKompasModelProperties(properties,encoded,error));
        KompasModelProperties decoded;
        assert(decodeKompasModelProperties(QByteArray("frame")+encoded+QByteArray("tail"),5,decoded,consumed,error));
        assert(consumed==encoded.size() && decoded.name==properties.name && decoded.materialName==properties.materialName);
        for(int change=0;change<6;++change) {
            auto bad=properties;
            if(change==0)bad.name=QString(65537,QChar('x'));
            if(change==1)bad.materialName=QString(65537,QChar('x'));
            if(change==2)bad.color=0x1000000;
            if(change==3)bad.material[2]=101;
            if(change==4)bad.nativeDensity=-1;
            if(change==5)bad.nativeDensity=std::numeric_limits<double>::quiet_NaN();
            QByteArray output="old";
            assert(!encodeKompasModelProperties(bad,output,error) && output.isEmpty());
        }
        assert(!decodeKompasModelProperties(fixture,-1,decoded,consumed,error));
        assert(!decodeKompasModelProperties(fixture,fixture.size()+1,decoded,consumed,error));
    }
    {
        // Independent footer: the aggregate is 35, while only the controller
        // vector in the header specifies the number of live controllers.
        const auto fixture=QByteArray::fromHex(
            "0117002300000012000000050000000400000000000000080000000000000000000000000c000000000100000000"
            "000000000000000000009a08000000");
        const std::map<quint16,quint16> registry{{23,0x4170},{24,0x507a}};
        KompasModelFooter footer;QString error;qsizetype consumed=0;QByteArray encoded;
        assert(decodeKompasModelFooter(fixture,0,registry,footer,consumed,error));
        assert(consumed==61 && footer.originId==23 && footer.nextMainName==2202);
        assert((footer.nativeCounters==std::array<quint64,4>{18,5,4,8}) && !footer.extendedState);
        assert(encodeKompasModelFooter(footer,registry,encoded,error) && encoded==fixture);
        for(bool extended:{false,true}) {
            footer.extendedState=extended;
            assert(encodeKompasModelFooter(footer,registry,encoded,error));
            assert(encoded.size()==(extended?92:61));
            KompasModelFooter decoded;
            const auto framed=QByteArray("frame")+encoded+QByteArray("tail");
            assert(decodeKompasModelFooter(framed,5,registry,decoded,consumed,error));
            assert(consumed==encoded.size() && decoded.extendedState==extended);
            QByteArray rewritten;
            assert(encodeKompasModelFooter(decoded,registry,rewritten,error) && rewritten==encoded);
            for(qsizetype end=0;end<encoded.size();++end) {
                decoded=footer;consumed=123;
                assert(!decodeKompasModelFooter(encoded.left(end),0,registry,decoded,consumed,error));
                assert(consumed==0 && decoded.nativeCounters[0]==0 && decoded.nextMainName==0);
            }
        }
        for(const auto offset:{0,3,31,35,38,43,44,67,71,72,80,84,91}) {
            auto corrupt=encoded;corrupt[offset]=char(uchar(corrupt[offset])^0x80);
            assert(!decodeKompasModelFooter(corrupt,0,registry,footer,consumed,error));
            assert(consumed==0);
        }
        assert(!decodeKompasModelFooter(fixture,0,{},footer,consumed,error));
        assert(!decodeKompasModelFooter(fixture,0,{{23,0x507a}},footer,consumed,error));
        assert(decodeKompasModelFooter(fixture,0,registry,footer,consumed,error));
        for(int change=0;change<4;++change) {
            auto bad=footer;
            if(change==0)bad.originId=24;
            if(change==1)bad.nextMainName=0;
            if(change==2)bad.nativeCounters[2]=std::numeric_limits<quint64>::max();
            if(change==3)bad.nativeCounters[0]=std::numeric_limits<quint32>::max();
            encoded="old";
            assert(!encodeKompasModelFooter(bad,registry,encoded,error) && encoded.isEmpty());
        }
        KompasModelHeader header;
        header.controllerCount=9;
        header.boxes[0]={-2,-3,-4,5,6,7};
        header.transform={0,1,0,0,-1,0,0,0,0,0,1,0,2,3,4,1};
        assert(encodeKompasModelHeader(header,encoded,error) && encoded.size()==283);
        // Check independent offsets and scalar ordering in the native layout.
        quint64 scalar=0;std::memcpy(&scalar,encoded.constData()+275,8);
        assert(scalar==9 && uchar(encoded[128])==0 && uchar(encoded[273])==0 && uchar(encoded[274])==1);
        double minX=0,maxX=0;std::memcpy(&minX,encoded.constData()+129,8);std::memcpy(&maxX,encoded.constData()+153,8);
        assert(minX==-2 && maxX==5);
        KompasModelHeader decoded;
        assert(decodeKompasModelHeader(encoded,0,decoded,consumed,error));
        assert(consumed==283 && decoded.controllerCount==9 && decoded.transform==header.transform && decoded.boxes==header.boxes);
        for(qsizetype end=0;end<encoded.size();++end) {
            decoded=header;consumed=123;
            assert(!decodeKompasModelHeader(encoded.left(end),0,decoded,consumed,error));
            assert(consumed==0 && decoded.controllerCount==0);
        }
        for(const auto offset:{128,273,274,277}) {
            auto corrupt=encoded;corrupt[offset]=char(uchar(corrupt[offset])^0x80);
            assert(!decodeKompasModelHeader(corrupt,0,decoded,consumed,error));
        }
        for(int change=0;change<4;++change) {
            auto bad=header;
            if(change==0)bad.controllerCount=65537;
            if(change==1)bad.transform[0]=std::numeric_limits<double>::infinity();
            if(change==2)bad.boxes[1][0]=std::numeric_limits<double>::quiet_NaN();
            if(change==3)bad.boxes[0][0]=10;
            QByteArray output="old";
            assert(!encodeKompasModelHeader(bad,output,error) && output.isEmpty());
        }
        assert(!decodeKompasModelHeader(encoded,-1,decoded,consumed,error));
        assert(!decodeKompasModelFooter(fixture,fixture.size()+1,registry,footer,consumed,error));
    }
    {
        // An independent native axis fixture has different serialization and
        // application names and a translated origin with direction Y.
        const auto fixture=QByteArray::fromHex(
            "0280702c010d000901f70100000001000100000041000000000200000076003400000000000000000003000000020000"
            "000000000001100011111000110100000000000000000000000003000000000000000000000056341200000000000000"
            "000000000000000000000000000000010001010000000000000000000000400000000000000840000000000000104000"
            "00000000000000000000000000f03f0000000000000000");
        QString error;KompasDatum axis;qsizetype consumed=0;QByteArray encoded;
        assert(decodeKompasDatum(fixture,0,{},axis,consumed,error));
        assert(consumed==fixture.size() && axis.kind==KompasDatum::Axis);
        assert(axis.objectId==13 && axis.nativeName==3 && axis.mainName==503 && axis.color==0x123456);
        assert(axis.placement[0]==2 && axis.placement[1]==3 && axis.placement[2]==4);
        assert(axis.placement[3]==0 && axis.placement[4]==1 && axis.placement[5]==0);
        assert(encodeKompasDatum(axis,{},encoded,error) && encoded==fixture);
        std::map<quint16,quint16> registry;
        for(int i=0;i<7;++i) {
            KompasDatum datum;
            datum.objectId=quint16(10+i);datum.nativeName=quint32(100+i);datum.mainName=quint32(500+i);
            datum.kind=i<3?KompasDatum::Plane:i<6?KompasDatum::Axis:KompasDatum::Origin;
            datum.title="Datum "+QString::number(i);
            if(i==6)datum.datumIds={10,11,12,13,14,15};
            assert(encodeKompasDatum(datum,registry,encoded,error));
            KompasDatum read;
            const auto framed=QByteArray("before")+encoded+QByteArray("after");
            assert(decodeKompasDatum(framed,6,registry,read,consumed,error));
            assert(consumed==encoded.size() && read.kind==datum.kind && read.datumIds==datum.datumIds);
            QByteArray rewritten;
            assert(encodeKompasDatum(read,registry,rewritten,error) && rewritten==encoded);
            for(qsizetype end=0;end<encoded.size();++end) {
                read=datum;consumed=123;
                assert(!decodeKompasDatum(encoded.left(end),0,registry,read,consumed,error));
                assert(consumed==0 && read.objectId==0 && read.datumIds.empty());
            }
            auto wrong=registry;wrong[datum.objectId]=0x6239;
            assert(!decodeKompasDatum(encoded,0,wrong,read,consumed,error));
            assert(!encodeKompasDatum(datum,wrong,rewritten,error) && rewritten.isEmpty());
            if(i==6) {
                wrong=registry;wrong[15]=0x507a;
                assert(!decodeKompasDatum(encoded,0,wrong,read,consumed,error));
                auto bad=datum;bad.datumIds[5]=14;
                assert(!encodeKompasDatum(bad,registry,rewritten,error));
                bad=datum;bad.datumIds.pop_back();
                assert(!encodeKompasDatum(bad,registry,rewritten,error));
            }
            registry.emplace(datum.objectId,i<3?0x507a:i<6?0x2c70:0x4170);
        }
        auto invalid=axis;invalid.placement[4]=2;
        assert(!encodeKompasDatum(invalid,{},encoded,error) && encoded.isEmpty());
        invalid=axis;invalid.placement[0]=std::numeric_limits<double>::quiet_NaN();
        assert(!encodeKompasDatum(invalid,{},encoded,error));
        invalid=axis;invalid.datumIds={1};
        assert(!encodeKompasDatum(invalid,{},encoded,error));
        assert(!decodeKompasDatum(fixture,-1,{},axis,consumed,error));
        assert(!decodeKompasDatum(fixture,fixture.size()+1,{},axis,consumed,error));
    }
    {
        // Independently framed operation with object ID 42, application name
        // 100, main name 1003 and body 4: these namespaces cannot be merged.
        // A rotated, translated native frame and ordered attributes exercise
        // meaningful payloads independently of the default writer values.
        const auto prefixFixture = QByteArray::fromHex(
            "02800128012a001901eb0300000001000800000049006d0070006f007200740065006400000000020000007600390007"
            "0000006500780063006c0075006400650000000000640000000200000000000000011000111110001101010000000000"
            "00000000000000000000010000000000000004000000000000000000000001000000000000000000000056341200050a"
            "0f14191e0001010000000000000000000000000000000100000000000000040000000000000000000000000000000000"
            "000000000000010100000000000000020040040163000000000100320000000000000000000000000000000000004000"
            "0000000000084000000000000010400000000000000000000000000000f03f0000000000000000000000000000f0bf00"
            "00000000000000000000000000000000000000000000000000000000000000000000000000f03f010200000001000000"
            "00000000");
        const auto suffixFixture = QByteArray::fromHex(
            "010001030000000000000002007f380203020303030301000100000000000000000300000042006f0078000400000011"
            "043b043e043a0404000000690064002d0039000200650102030203030303010001000000000000000000020017620203"
            "0203030303010001000000000000000056341200ffffffff04000000");
        QString error;
        qsizetype consumed = 0;
        KompasImportedOperationPrefix prefix;
        const auto framed = QByteArray("before") + prefixFixture + QByteArray("after");
        assert(decodeKompasImportedOperationPrefix(framed, 6, prefix, consumed, error));
        assert(consumed == 340 && prefix.objectId == 42 && prefix.applicationName == 100);
        assert(prefix.mainName == 1003 && prefix.bodyNumber == 4 && prefix.nativeType == 25);
        assert(prefix.title == "Imported" && prefix.variableName == "v9" && prefix.exclusionPrompt == "exclude");
        assert(prefix.color == 0x123456 && prefix.material[0] == 5 && prefix.material[5] == 30);
        assert(prefix.frameName == 99 && prefix.shellCount == 1);
        assert((prefix.placement == std::array<double,12>{2,3,4,0,1,0,-1,0,0,0,0,1}));
        QByteArray encoded;
        assert(encodeKompasImportedOperationPrefix(prefix, encoded, error) && encoded == prefixFixture);
        const auto saved = prefix;
        for (qsizetype end = 0; end < prefixFixture.size(); ++end) {
            prefix = saved; consumed = 123;
            assert(!decodeKompasImportedOperationPrefix(prefixFixture.left(end), 0, prefix, consumed, error));
            assert(consumed == 0 && prefix.objectId == 0 && prefix.applicationName == 0 && !error.isEmpty());
        }
        for (const qsizetype at : std::vector<qsizetype>{0,2,4,8,13,36,65,73,81,89,99,106,174,207,219,327}) {
            auto damaged = prefixFixture;
            damaged[at] = char(uchar(damaged[at]) ^ 4);
            assert(!decodeKompasImportedOperationPrefix(damaged, 0, prefix, consumed, error));
            assert(consumed == 0 && prefix.applicationName == 0);
        }
        assert(!decodeKompasImportedOperationPrefix(prefixFixture, -1, prefix, consumed, error));
        assert(!decodeKompasImportedOperationPrefix(prefixFixture, prefixFixture.size()+1, prefix, consumed, error));
        for (int change = 0; change < 9; ++change) {
            auto invalid = saved;
            switch (change) {
            case 0: invalid.mainName = 0; break;
            case 1: invalid.applicationName = 0xfffffffb; break;
            case 2: invalid.bodyNumber = 0; break;
            case 3: invalid.shellCount = 2; break;
            case 4: invalid.material[0] = 101; break;
            case 5: invalid.color = 0x1000000; break;
            case 6: invalid.placement[0] = std::numeric_limits<double>::infinity(); break;
            case 7: invalid.placement[6] = 1; break; // reflected frame
            case 8: invalid.title = QString(65537, QChar('x')); break;
            }
            encoded = "stale";
            assert(!encodeKompasImportedOperationPrefix(invalid, encoded, error) && encoded.isEmpty());
        }
        KompasImportedOperationSuffix suffix;
        const auto suffixFramed = QByteArray("before") + suffixFixture + QByteArray("after");
        assert(decodeKompasImportedOperationSuffix(suffixFramed, 6, suffix, consumed, error));
        assert(consumed == 124 && suffix.bodyNumber == 4 && suffix.attributes.size() == 3);
        assert(suffix.attributes[0].kind == KompasOperationAttribute::Strings);
        assert(suffix.attributes[0].strings[0] == "Box" && suffix.attributes[0].strings[1] == QString::fromUtf8("Блок"));
        assert(suffix.attributes[0].strings[2] == "id-9");
        assert(suffix.attributes[1].kind == KompasOperationAttribute::Boolean && !suffix.attributes[1].boolean);
        assert(suffix.attributes[2].color == 0x123456);
        assert(encodeKompasImportedOperationSuffix(suffix, encoded, error) && encoded == suffixFixture);
        const auto savedSuffix = suffix;
        for (qsizetype end = 0; end < suffixFixture.size(); ++end) {
            suffix = savedSuffix; consumed = 123;
            assert(!decodeKompasImportedOperationSuffix(suffixFixture.left(end), 0, suffix, consumed, error));
            assert(consumed == 0 && suffix.attributes.empty() && suffix.bodyNumber == 0);
        }
        for (const qsizetype at : std::vector<qsizetype>{0,3,11,13,15,25,33,69,71,73,83,89,91,92,94,96,106,115,116}) {
            auto damaged = suffixFixture;
            damaged[at] = char(uchar(damaged[at]) ^ 4);
            assert(!decodeKompasImportedOperationSuffix(damaged, 0, suffix, consumed, error));
        }
        auto invalid = savedSuffix;
        invalid.attributes.push_back(invalid.attributes[1]);
        assert(!encodeKompasImportedOperationSuffix(invalid, encoded, error) && encoded.isEmpty());
        invalid = savedSuffix; invalid.nativeFlags[0] = 2;
        assert(!encodeKompasImportedOperationSuffix(invalid, encoded, error));
        invalid = savedSuffix; invalid.bodyNumber = 0;
        assert(!encodeKompasImportedOperationSuffix(invalid, encoded, error));
        invalid = savedSuffix; invalid.attributes[0].strings[2] = QString(65537, QChar('x'));
        assert(!encodeKompasImportedOperationSuffix(invalid, encoded, error));
    }
    {
        // Independently framed fixture: two vertex proxies (one removed), an
        // edge and a black face. The second face field is 3, not the high word
        // of an attribute count; the owner is body 2, not a pointer count.
        const auto fixture = QByteArray::fromHex(
            "01010000000000000002007a0c070000000200000000000000"
            "0280697c01040002070000002a00000000020002000000010100"
            "0280697c01080002070000002a0000000002000200000000"
            "01010000000000000002007a0c090000000100000000000000"
            "0280081401050002090000002a00000000020002000000010200"
            "01010000000000000002007a0c0b0000000100000000000000"
            "02800f11010600020b0000002a00000000020002000000010300"
            "00000000323c505064320000000003000000");
        const std::map<quint16,quint16> registry{{1,0x0b04},{2,0x4313},{3,0x666e}};
        KompasTopologyTables tables;
        qsizetype consumed = 0;
        QString error;
        const auto framed = QByteArray("prefix") + fixture + QByteArray("suffix");
        assert(decodeKompasTopologyTables(framed,6,registry,tables,consumed,error));
        assert(consumed==fixture.size() && tables.groups[0][0].proxies.size()==2);
        assert(tables.groups[0][0].proxies[0].bodyNumber==2);
        assert(tables.groups[0][0].proxies[0].mathId==1);
        assert(!tables.groups[0][0].proxies[1].mathId);
        const auto& style=*tables.groups[2][0].proxies[0].faceStyle;
        assert(style.color==0 && style.field0==0 && style.field1==3);
        QByteArray encoded;
        assert(encodeKompasTopologyTables(tables,registry,encoded,error) && encoded==fixture);
        auto invalid=tables;
        invalid.groups[1][0].proxies[0].mathId=1; // edge points at a vertex
        assert(!encodeKompasTopologyTables(invalid,registry,encoded,error) && encoded.isEmpty());
        invalid=tables;invalid.groups[1][0].proxies[0].id=4;
        assert(!encodeKompasTopologyTables(invalid,registry,encoded,error) && encoded.isEmpty());
        invalid=tables;invalid.groups[1][0].proxies[0].id=3;
        assert(!encodeKompasTopologyTables(invalid,registry,encoded,error));
        invalid=tables;invalid.groups[1][0].proxies[0].name.words[0]=123;
        assert(!encodeKompasTopologyTables(invalid,registry,encoded,error));
        invalid=tables;invalid.groups[0][0].proxies[0].faceStyle=KompasFaceStyle{};
        assert(!encodeKompasTopologyTables(invalid,registry,encoded,error));
        for (qsizetype end=0;end<fixture.size();++end) {
            tables=invalid;consumed=123;
            assert(!decodeKompasTopologyTables(fixture.left(end),0,registry,tables,consumed,error));
            assert(consumed==0 && tables.groups[0].empty() && tables.groups[2].empty());
        }
        auto wrongClass=registry;wrongClass[2]=0x666e;
        assert(!decodeKompasTopologyTables(fixture,0,wrongClass,tables,consumed,error));
        auto collided=registry;collided[8]=0x601e;
        assert(!decodeKompasTopologyTables(fixture,0,collided,tables,consumed,error));
        assert(!decodeKompasTopologyTables(fixture,-1,registry,tables,consumed,error));
        auto oversized=fixture;for (int i=1;i<9;++i)oversized[i]=char(0xff);
        assert(!decodeKompasTopologyTables(oversized,0,registry,tables,consumed,error));
    }
    {
        // Independent application-state framing with a nontrivial body name,
        // no proxies, and both supported footer flag groups. Prefix/suffix
        // bytes are outside the owning record extent and must remain unread.
        const auto fixture = QByteArray::fromHex(
            "01000101000000000000000200470f02030203030303010001"
            "0000000000000000785634120300000000000000"
            "010000000000000000010000000000000000010000000000000000"
            "00000000010101010000000001010000");
        const auto framed = QByteArray("prefix") + fixture + QByteArray("suffix");
        KompasBodyApplication application;
        QString error;
        qsizetype consumed = 0;
        assert(decodeKompasBodyApplication(framed,6,{},application,consumed,error));
        assert(consumed==fixture.size() && application.state.nativeName==0x12345678);
        assert((application.state.nativeFlags==std::array<quint8,3>{1,0,1}));
        assert((application.state.nativeFooterFlags0==std::array<quint8,4>{1,1,1,1}));
        assert((application.state.nativeFooterFlags1==std::array<quint8,4>{1,1,0,0}));
        QByteArray encoded;
        assert(encodeKompasBodyApplication(application,{},encoded,error) && encoded==fixture);
        const auto original=application;
        for(qsizetype end=0;end<fixture.size();++end) {
            application=original;consumed=99;
            assert(!decodeKompasBodyApplication(fixture.left(end),0,{},application,consumed,error));
            assert(consumed==0 && application.state.nativeName==0 && application.topology.groups[0].empty());
        }
        for(const qsizetype at:{qsizetype(1),qsizetype(3),qsizetype(13),qsizetype(15),
                              qsizetype(25),qsizetype(37),qsizetype(41),fixture.size()-1}) {
            auto invalid=fixture;invalid[at]=char(0xfe);
            assert(!decodeKompasBodyApplication(invalid,0,{},application,consumed,error));
            assert(consumed==0 && application.state.nativeName==0);
        }
        assert(!decodeKompasBodyApplication(fixture,-1,{},application,consumed,error));
        assert(!decodeKompasBodyApplication(fixture,fixture.size()+1,{},application,consumed,error));
        for(const quint32 name:{0u,0xfffffffbu,0xffffffffu}) {
            application=original;application.state.nativeName=name;encoded="stale";
            assert(!encodeKompasBodyApplication(application,{},encoded,error) && encoded.isEmpty());
        }
        application=original;application.state.nativeFooterFlags0[2]=2;
        assert(!encodeKompasBodyApplication(application,{},encoded,error) && encoded.isEmpty());
        const auto link=QByteArray::fromHex("01000000000000000100000078563412");
        quint32 name=0;
        assert(decodeKompasBodyApplicationLink(link,name,error) && name==0x12345678);
        assert(encodeKompasBodyApplicationLink(name,encoded,error) && encoded==link);
        for(qsizetype end=0;end<link.size();++end) {
            name=123;
            assert(!decodeKompasBodyApplicationLink(link.left(end),name,error) && name==0);
        }
        assert(!decodeKompasBodyApplicationLink(link+QByteArray("extra"),name,error) && name==0);
        for(const qsizetype at:{qsizetype(0),qsizetype(8)}) {
            auto invalid=link;invalid[at]=2;
            assert(!decodeKompasBodyApplicationLink(invalid,name,error) && name==0);
        }
        assert(!encodeKompasBodyApplicationLink(0,encoded,error) && encoded.isEmpty());
    }
    {
        using C = detail::KompasUvCurve;
        const auto cubic = [](double lo, double hi, std::array<double,2> from,
                              std::array<double,2> to) {
            C c; c.kind=C::Hermite; c.first=lo; c.last=hi;
            c.poles={from,{}, {},to};
            for (int k=0;k<2;++k) {
                c.poles[1][k]=(2*from[k]+to[k])/3;
                c.poles[2][k]=(from[k]+2*to[k])/3;
            }
            return c;
        };
        // Identical cornered boundaries with different knot partitions. The
        // corner must remain a corner; added intervals may not change either
        // curve's parameterization or one-sided derivatives.
        C a; a.kind=C::Contour; a.last=1;
        a.pieces={cubic(0,.5,{0,0},{1,1}),cubic(0,.5,{1,1},{2,0})};
        C b=a;
        b.pieces={cubic(0,.25,{0,0},{.5,.5}),cubic(0,.25,{.5,.5},{1,1}),
                  cubic(0,.5,{1,1},{2,0})};
        std::size_t nextKey=100;
        detail::harmonizeKompasUvContours(a,b,nextKey);
        assert(a.pieces.size()==3 && b.pieces.size()==3 && nextKey==106);
        for (int i=0;i<=128;++i) {
            const double t=i/128.0;
            const std::array<double,2> expected{2*t,t<=.5?2*t:2-2*t};
            for(const auto* c:{&a,&b}) {
                const auto point=detail::kompasUvPoint(*c,t);
                for(int k=0;k<2;++k)assert(std::fabs(point[k]-expected[k])<1e-14);
            }
        }
        assert(std::fabs(detail::kompasUvDerivative(a.pieces[1],.25)[1]-2)<1e-14);
        assert(std::fabs(detail::kompasUvDerivative(a.pieces[2],0)[1]+2)<1e-14);

        // A small but nonzero corner must not be welded to one tangent merely
        // because its derivative jump is below a geometric tolerance.
        auto first=cubic(0,.5,{0,0},{.5,.5});
        auto second=cubic(.5,1,{.5,.5},{1,1});
        first.poles={{{0,0}},{{.125,.125}},{{.375,.375}},{{.5,.5}}};
        second.poles={{{.5,.5}},{{.625,.625}},{{.875,.875}},{{1,1}}};
        assert(detail::canJoinKompasUvHermitePieces({first,second}));
        second.poles[1][1]+=1e-14;
        assert(!detail::canJoinKompasUvHermitePieces({first,second}));

        // A nonzero source origin and a contour's implicit zero origin must
        // describe the same boundary after exact affine reparameterization.
        C shifted;shifted.kind=C::Hermite;shifted.first=7;shifted.last=11;
        shifted.pieces={cubic(7,9,{0,0},{1,1}),cubic(9,11,{1,1},{2,0})};
        C local;local.kind=C::Contour;local.last=4;
        local.pieces={cubic(0,2,{0,0},{1,1}),cubic(0,2,{1,1},{2,0})};
        detail::normalizeKompasUvPolynomial(shifted);
        detail::normalizeKompasUvPolynomial(local);
        for(int i=0;i<=128;++i) {
            const double t=i/128.0;
            const std::array<double,2> expected{2*t,t<=.5?2*t:2-2*t};
            for(const auto* c:{&shifted,&local}) {
                const auto point=detail::kompasUvPoint(*c,t);
                for(int k=0;k<2;++k)assert(std::fabs(point[k]-expected[k])<1e-14);
            }
        }

        // A curved cubic split against an already split counterpart. These
        // controls are an independent de Casteljau split at one half.
        C curve;curve.kind=C::Hermite;curve.first=0;curve.last=1;
        curve.poles={{{0,0}},{{0,1}},{{1,1}},{{1,0}}};
        a.kind=b.kind=C::Contour;a.last=b.last=1;a.pieces={curve};
        C left=curve,right=curve;left.last=right.last=.5;
        left.poles={{{0,0}},{{0,.5}},{{.25,.75}},{{.5,.75}}};
        right.poles={{{.5,.75}},{{.75,.75}},{{1,.5}},{{1,0}}};
        b.pieces={left,right};
        detail::harmonizeKompasUvContours(a,b,nextKey);
        for (int i=0;i<=128;++i) {
            const double t=i/128.0;
            const std::array<double,2> expected{3*t*t-2*t*t*t,3*t*(1-t)};
            for(const auto* c:{&a,&b}) {
                const auto point=detail::kompasUvPoint(*c,t);
                for(int k=0;k<2;++k)assert(std::fabs(point[k]-expected[k])<1e-14);
            }
        }
        constexpr double pi=3.14159265358979323846;
        C arc;arc.kind=C::Arc;arc.a=arc.b=2;arc.x={1,0};arc.y={0,1};arc.first=0;arc.last=pi;
        a.last=b.last=pi;a.pieces={arc};
        left=right=arc;left.last=pi/2;right.first=pi/2;b.pieces={left,right};
        detail::harmonizeKompasUvContours(a,b,nextKey);
        for (int i=0;i<=128;++i) {
            const double t=pi*i/128;
            const auto point=detail::kompasUvPoint(a,t);
            assert(std::fabs(point[0]-2*std::cos(t))<1e-14 && std::fabs(point[1]-2*std::sin(t))<1e-14);
        }
        arc.first=-pi/3;arc.last=pi/6;
        detail::contourizeKompasUvArc(arc,nextKey);
        assert(arc.first==0 && std::fabs(arc.last-pi/2)<1e-14);
        detail::normalizeKompasUvPolynomial(local,arc.last);
        assert(local.last==arc.last);
        for(int i=0;i<=128;++i) {
            const double t=arc.last*i/128;
            const auto point=detail::kompasUvPoint(arc,t);
            assert(std::fabs(point[0]-2*std::cos(t-pi/3))<1e-14);
            assert(std::fabs(point[1]-2*std::sin(t-pi/3))<1e-14);
            const double f=i/128.0;
            const auto polynomial=detail::kompasUvPoint(local,t);
            assert(std::fabs(polynomial[0]-2*f)<1e-14);
            assert(std::fabs(polynomial[1]-(f<=.5?2*f:2-2*f))<1e-14);
        }
        a.pieces.clear();bool rejected=false;
        try {detail::harmonizeKompasUvContours(a,b,nextKey);} catch(const std::runtime_error&) {rejected=true;}
        assert(rejected);
    }
    const QByteArray first("\0\1\2\xff", 4);
    const QByteArray second("exact record boundaries");
    QByteArray contents("KF", 2);
    contents += deflate(first);
    contents += deflate(second);
    const qsizetype tailOffset = contents.size();
    contents += QByteArray("\x80\x43\x30\x00", 4);

    KompasContentsRecords records;
    QString error;
    assert(decodeKompasContentsRecords(contents, records, error));
    assert(error.isEmpty());
    assert(records.records.size() == 2);
    assert(records.records[0].offset == 2);
    assert(records.records[0].decoded == first);
    assert(records.records[1].offset ==
           2 + records.records[0].compressedSize);
    assert(records.records[1].decoded == second);
    assert(records.decodedBytes == quint64(first.size() + second.size()));
    assert(records.tailOffset == tailOffset);
    assert(records.tail == QByteArray("\x80\x43\x30\x00", 4));

    QByteArray corrupt = contents;
    corrupt[2 + records.records[0].compressedSize - 1] ^= char(1);
    assert(!decodeKompasContentsRecords(corrupt, records, error));
    assert(records.records.empty());
    assert(!error.isEmpty());
    assert(!decodeKompasContentsRecords(QByteArray("KF\x78\x9c", 4), records, error));
    assert(!decodeKompasContentsRecords(QByteArray("KF", 2), records, error));
    assert(!decodeKompasContentsRecords(QByteArray("XX", 2), records, error));

    // A hand-specified native index: two compressed records (14 and 12
    // bytes), then a 17-byte opaque catalog. Addresses exclude the KF tag;
    // the catalog is identified by cluster number 2, not byte position 26.
    KompasStoragePrefix prefix;
    assert(prepareKompasStorageRecords({QByteArray::fromHex("0000000007000000"),
                                       QByteArray::fromHex("11100011")}, prefix, error));
    assert(prefix.records.size() == 2);
    assert(prefix.records[0].compressedSize == 14);
    assert(prefix.records[1].compressedSize == 12);
    const QByteArray catalog(17, char(0x80));
    KompasStorageImage image;
    assert(finishKompasStorage(prefix, catalog, image, error));
    const QByteArray golden = QByteArray::fromHex(
        "4b4601100011" "0300000000000000" "0010"
        "0100000000000000" "2b00000000000000" "00000000"
        "0e00" "0e00000000000000"
        "0c00" "1a00000000000000"
        "1100" "0200000000000000");
    assert(image.sysInfo == golden);
    KompasStorageIndex index;
    assert(decodeKompasStorageIndex(image.contents, golden, index, error));
    assert(index.clusterCount == 3 && index.firstCatalogCluster == 2);
    assert(index.catalogOffset == 28 && index.catalogClusterCount == 1);

    // The physical storage image is also emitted as an atomic modern ZIP.
    // Both members are stored verbatim; the normal importer must recover the
    // same Contents bytes, while SysInfo remains available to the native
    // storage validator.
    {
        QTemporaryDir dir;
        assert(dir.isValid());
        const QString path = dir.filePath(QStringLiteral("storage.m3d"));
        assert(writeKompasStorageArchive(path, image, error));
        QFile archiveFile(path);
        assert(archiveFile.open(QIODevice::ReadOnly));
        const QByteArray archive = archiveFile.readAll();
        assert(archive.startsWith(QByteArray("PK\x03\x04", 4)));
        QByteArray extracted;
        assert(readKompasContents(path, extracted, error));
        assert(extracted == image.contents);
        assert(storedZipMember(archive, QByteArrayLiteral("SysInfo")) == image.sysInfo);
        const QByteArray before = archive;
        auto invalid = image;
        invalid.sysInfo[6] ^= char(1);
        assert(!writeKompasStorageArchive(path, invalid, error));
        assert(archiveFile.seek(0));
        assert(archiveFile.readAll() == before);
    }

    // Independent catalog bytes: a numeric root stream and a text directory
    // containing another numeric stream. Cluster references use the compressed
    // storage locations, while the directory's parent is an object reference.
    const QByteArray nativeCatalog = QByteArray::fromHex(
        "80433001100011" "0200000000000000" "0110001111100011" "000000040001" "0200000000000000"
        "02001f4f" "0200000000000000" "0110001111100011" "010000" "00" "007200"
        "0100000000000000" "0000000000000000" "0000"
        "02807f57010100" "01100011" "0200000000000000" "0110001111100011"
        "010000" "00" "020400000062006f0064007900" "01" "0100000000000000"
        "02001f4f" "0200000000000000" "0110001111100011" "010100" "00" "006e00"
        "0100000000000000" "0100000000000000" "0000" "2a000000");
    KompasCatalog decodedCatalog;
    assert(decodeKompasCatalog(nativeCatalog,prefix.records,decodedCatalog,error));
    assert(decodedCatalog.entries.size()==2 && decodedCatalog.lastObjectId==42);
    assert(decodedCatalog.entries[0].numericName==114 && decodedCatalog.entries[0].recordIndex==0);
    assert(decodedCatalog.entries[1].textName=="body" && decodedCatalog.entries[1].directory);
    assert(decodedCatalog.entries[1].children[0].numericName==110 && decodedCatalog.entries[1].children[0].recordIndex==1);
    QByteArray encodedCatalog;
    assert(encodeKompasCatalog(decodedCatalog,prefix,encodedCatalog,error));
    assert(encodedCatalog==nativeCatalog);
    assert(finishKompasStorage(prefix,encodedCatalog,image,error));
    assert(decodeKompasStorageIndex(image.contents,image.sysInfo,index,error));
    assert(decodeKompasCatalog(image.contents.mid(index.catalogOffset),index.records,decodedCatalog,error));
    for(qsizetype offset:{qsizetype(1),qsizetype(29),qsizetype(58),qsizetype(72)}) {
        auto bad=nativeCatalog;bad[offset]^=char(1);
        assert(!decodeKompasCatalog(bad,prefix.records,decodedCatalog,error));
        assert(decodedCatalog.entries.empty() && !error.isEmpty());
    }
    assert(!decodeKompasCatalog(nativeCatalog.left(nativeCatalog.size()-1),prefix.records,decodedCatalog,error));
    assert(!decodeKompasCatalog(nativeCatalog+QByteArray(1,'\0'),prefix.records,decodedCatalog,error));
    assert(decodeKompasCatalog(nativeCatalog,prefix.records,decodedCatalog,error));
    auto missingOwner=decodedCatalog;missingOwner.entries.pop_back();
    assert(!encodeKompasCatalog(missingOwner,prefix,encodedCatalog,error));
    assert(encodedCatalog.isEmpty());
    auto duplicateOwner=decodedCatalog;duplicateOwner.entries[1].children[0].recordIndex=0;
    assert(!encodeKompasCatalog(duplicateOwner,prefix,encodedCatalog,error));
    auto duplicateName=decodedCatalog;duplicateName.entries.push_back(duplicateName.entries[0]);
    assert(!encodeKompasCatalog(duplicateName,prefix,encodedCatalog,error));
    auto separateNames=decodedCatalog;
    KompasCatalogEntry sameNameDirectory;sameNameDirectory.directory=true;sameNameDirectory.numericName=114;
    separateNames.entries.push_back(sameNameDirectory);
    assert(encodeKompasCatalog(separateNames,prefix,encodedCatalog,error));
    assert(decodeKompasCatalog(encodedCatalog,prefix.records,decodedCatalog,error));
    assert(decodedCatalog.entries.size()==3 && decodedCatalog.entries.back().directory);
    auto invalidLocations=prefix;
    invalidLocations.records[0].clusterCount=std::numeric_limits<quint64>::max();
    assert(!encodeKompasCatalog(separateNames,invalidLocations,encodedCatalog,error));
    assert(encodedCatalog.isEmpty());
    invalidLocations=prefix;invalidLocations.records[1].firstCluster=0;
    assert(!decodeKompasCatalog(nativeCatalog,invalidLocations.records,decodedCatalog,error));
    assert(decodedCatalog.entries.empty());

    // Incompressible data crosses physical cluster boundaries within ONE
    // record. The next record must start in a fresh cluster; a catalog that
    // spans three clusters carries three consecutive cluster references.
    QByteArray large(20000, Qt::Uninitialized);
    quint32 random = 0x12345678;
    for (char& c : large) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        c = char(random & 0xff);
    }
    const QByteArray longCatalog(8193, char(0x80));
    assert(prepareKompasStorageRecords({large, first, QByteArray()}, prefix, error));
    assert(prefix.records[0].clusterCount >= 5);
    assert(prefix.records[1].firstCluster == prefix.records[0].clusterCount);
    assert(finishKompasStorage(prefix, longCatalog, image, error));
    assert(decodeKompasStorageIndex(image.contents, image.sysInfo, index, error));
    assert(index.catalogClusterCount == 3);
    assert(index.firstCatalogCluster == prefix.records[2].firstCluster + 1);
    KompasCatalog multiCluster;
    for(std::size_t i=0;i<prefix.records.size();++i) {
        KompasCatalogEntry entry;entry.numericName=quint16(i);entry.recordIndex=i;
        multiCluster.entries.push_back(entry);
    }
    assert(encodeKompasCatalog(multiCluster,prefix,encodedCatalog,error));
    assert(decodeKompasCatalog(encodedCatalog,prefix.records,decodedCatalog,error));
    assert(decodedCatalog.entries.size()==3 && decodedCatalog.entries[1].recordIndex==1);
    assert(decodeKompasContentsRecords(image.contents, records, error));
    assert(records.records.size() == 3 && records.records[0].decoded == large);
    assert(records.records[1].decoded == first && records.records[2].decoded.isEmpty());
    assert(records.tail == longCatalog);

    // A geometrically readable stream with stale native addresses must fail
    // this independent storage check. Also reject forged u64 counts before
    // any allocation, trailing bytes, wrong versions, checksum damage and
    // catalog references that accidentally use record ordinals.
    for (qsizetype at : {qsizetype(2), qsizetype(6), qsizetype(14), qsizetype(16),
                         qsizetype(24), qsizetype(32), qsizetype(36), qsizetype(38),
                         image.sysInfo.size() - 8}) {
        QByteArray changed = image.sysInfo;
        changed[at] ^= char(1);
        assert(!decodeKompasStorageIndex(image.contents, changed, index, error));
        assert(index.records.empty() && !error.isEmpty());
    }
    assert(!decodeKompasStorageIndex(image.contents, image.sysInfo + 'x', index, error));
    for (qsizetype length : {qsizetype(0), qsizetype(35), image.sysInfo.size() - 1})
        assert(!decodeKompasStorageIndex(image.contents, image.sysInfo.left(length), index, error));
    QByteArray wrongCounts = image.sysInfo;
    wrongCounts.replace(6, 8, QByteArray(8, char(0xff)));
    assert(!decodeKompasStorageIndex(image.contents, wrongCounts, index, error));
    QByteArray wrongChecksum = image.contents;
    wrongChecksum[prefix.records[0].offset + prefix.records[0].compressedSize - 1] ^= char(1);
    assert(!decodeKompasStorageIndex(wrongChecksum, image.sysInfo, index, error));
    KompasStoragePrefix changedPrefix = prefix;
    changedPrefix.records[1].firstCluster = 1;
    assert(!finishKompasStorage(changedPrefix, longCatalog, image, error));
    assert(image.contents.isEmpty() && image.sysInfo.isEmpty());
    assert(!finishKompasStorage(prefix, {}, image, error));
    assert(!finishKompasStorage(prefix, deflate("ambiguous catalog"), image, error));
    assert(image.contents.isEmpty() && image.sysInfo.isEmpty());
    assert(!prepareKompasStorageRecords({}, prefix, error));
    assert(prefix.contents.isEmpty() && prefix.records.empty());

    // The public sample supplies a regression check for the actual record
    // boundary layer. It is optional because it is not redistributed here.
    QFile sample(QStringLiteral("/private/tmp/cadnext-kompas-sample.m3d"));
    if (sample.exists()) {
        // The ZIP entry extraction is exercised by readKompasModelInfo; this
        // test passes its known stored Contents member to the record decoder.
        assert(sample.open(QIODevice::ReadOnly));
        const QByteArray archive = sample.readAll();
        const qsizetype contentsName = archive.indexOf("Contents");
        assert(contentsName > 0);
        const qsizetype localHeader = contentsName - 30;
        assert(localHeader >= 0);
        assert(archive.mid(localHeader, 4) == QByteArray("PK\x03\x04", 4));
        const auto u16 = [&](qsizetype at) -> quint16 {
            return quint16(quint8(archive[at])) |
                   (quint16(quint8(archive[at + 1])) << 8);
        };
        const auto u32 = [&](qsizetype at) -> quint32 {
            return quint32(u16(at)) | (quint32(u16(at + 2)) << 16);
        };
        assert(u16(localHeader + 8) == 0);
        const qsizetype dataAt = localHeader + 30 + u16(localHeader + 26) +
                                 u16(localHeader + 28);
        const QByteArray realContents = archive.mid(dataAt, u32(localHeader + 18));
        assert(realContents.size() == 101182);
        assert(decodeKompasContentsRecords(realContents, records, error));
        assert(records.records.size() == 484);
        assert(records.decodedBytes == 250584);
        assert(records.tailOffset == 62389);
        assert(records.tail.size() == 38793);
        assert(records.records[442].decoded.size() == 77948);
        assert(records.records[452].decoded.size() == 36557);

        std::vector<KompasCylindricalFace> faces;
        assert(readKompasCylindricalFaces(records, faces, error));
        assert(faces.size() == 5);
        const quint16 expectedSurfaceIds[] = {0x53f, 0x542, 0x545, 0x548, 0x54b};
        const quint16 expectedFaceIds[] = {0x6c7, 0x6c6, 0x6d7, 0x6d8, 0x6d6};
        const double expectedRadii[] = {1, 1, 2.5, 2.5, 2.5};
        for (std::size_t i = 0; i < faces.size(); ++i) {
            assert(faces[i].surfaceNodeId == expectedSurfaceIds[i]);
            assert(faces[i].faceNodeId == expectedFaceIds[i]);
            assert(std::fabs(faces[i].radius - expectedRadii[i]) < 1e-12);
            assert(std::fabs(faces[i].length - 10) < 1e-12);
        }
        assert(std::fabs(faces[0].origin[1] - 11.248967635572484) < 1e-12);
        assert(std::fabs(faces[0].origin[2] - 14.99633679023703) < 1e-12);

        std::vector<KompasCylindricalFace> fileFaces;
        assert(readKompasCylindricalFacesFromFile(
            QStringLiteral("/private/tmp/cadnext-kompas-sample.m3d"), fileFaces, error));
        assert(fileFaces.size() == faces.size());
        assert(fileFaces.front().surfaceNodeId == faces.front().surfaceNodeId);

        KompasContentsRecords changed = records;
        QByteArray& graph = changed.records[452].decoded;
        const qsizetype cylinder = graph.indexOf(
            QByteArray("\x02\x80\x5d\x14\x01\x3f\x05", 7));
        assert(cylinder >= 0);
        graph.replace(cylinder + 151, 8,
                      QByteArray("\0\0\0\0\0\0\0\x40", 8)); // r = 2
        std::vector<KompasCylindricalFace> changedFaces;
        assert(readKompasCylindricalFaces(changed, changedFaces, error));
        assert(changedFaces.size() == 4);

#ifdef CADNEXT_WITH_OCCT
        cadnext::kernel::OcctKernel kernel;
        std::vector<cadnext::kernel::ShapeHandle> shapes;
        assert(makeKompasCylindricalFaces(faces, kernel, shapes, error));
        assert(shapes.size() == faces.size());
        for (const auto& shape : shapes) {
            assert(kernel.isShapeValid(shape));
            const auto brep = kernel.exportBRep(shape);
            assert(brep.isOk() && !brep.value().empty());
        }
#endif
    }
}
