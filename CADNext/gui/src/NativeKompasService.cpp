#include "cadnext/gui/NativeKompasService.hpp"

#include <QObject>
#include <QDate>
#include <QTime>

#include <cmath>
#include <cstring>
#include <algorithm>
#include <cstdio>
#include <set>
#include <stdexcept>
#include <string>

namespace cadnext::gui {
namespace {

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("truncated");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value) throw std::runtime_error("unsupported");
    }
    QString string() {
        const auto count = number(4);
        if (count > 65536 || count * 2 > quint64(bytes.size() - at)) throw std::runtime_error("string");
        QString value;
        for (quint64 i = 0; i < count; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
    void end() const {
        if (at != bytes.size()) throw std::runtime_error("trailing");
    }
};

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void zeros(int count) { bytes.append(count, '\0'); }
    void string(const QString& value) {
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
};

// A new, unnumbered object of a native class: 02, flag 00, the class (u16).
void newObject(Writer& w, quint16 classId) {
    w.number(2, 1);
    w.number(0, 1);
    w.number(classId, 2);
}
void expectNewObject(Reader& r, quint16 classId) {
    r.expect(2, 1);
    r.expect(0, 1);
    r.expect(classId, 2);
}

// Each record's fields in the observed order, written or checked. `version` is
// the application file version (/#113) and only that record reads or writes it.
template <typename Field>
void layout(KompasServiceRecord record, Field&& field, quint64 version) {
    switch (record) {
    case KompasServiceRecord::ApplicationVersion:
        field(version, 4);
        return;
    case KompasServiceRecord::ModelSet100:
    case KompasServiceRecord::Document205:
        // A version byte and an empty list: two empty counts and a closing word.
        field(1, 1);
        field(0, 8);
        field(0, 8);
        field(0, 4);
        return;
    case KompasServiceRecord::ModelSet500:
        // A null reference, a native constant (0x00017f65 in every sample, its role
        // not known) and empty fields.
        field(0, 1);
        field(0x00017f65, 4);
        field(0, 4);
        field(0, 2);
        field(0, 1);
        return;
    case KompasServiceRecord::ModelSet700:
    case KompasServiceRecord::Model210:
    case KompasServiceRecord::Document230:
    case KompasServiceRecord::Document280:
        field(0, 8); // an empty list
        return;
    case KompasServiceRecord::Model180:
        field(0, 8);
        field(0, 1);
        field(1, 1); // a native state flag, set in every sample
        field(0, 8);
        return;
    case KompasServiceRecord::Document260:
        // One object of native class 0x6c77 whose single field is 1, then empty fields.
        field(2, 1);
        field(0, 1);
        field(0x6c77, 2);
        field(1, 4);
        field(0, 8);
        field(0, 1);
        return;
    case KompasServiceRecord::Document290:
        field(0, 8);
        field(0, 1);
        field(0xffffffffu, 4); // a null 32-bit reference
        return;
    case KompasServiceRecord::Passwords:
        // No password: an empty list and a clear flag.
        field(0, 8);
        field(0, 1);
        return;
    case KompasServiceRecord::Document114:
        field(0, 4);
        field(7, 4);
        return;
    case KompasServiceRecord::Model109:
        field(0, 4);
        return;
    case KompasServiceRecord::View: {
        const auto real = [&](double value) {
            quint64 bits;
            std::memcpy(&bits, &value, sizeof bits);
            field(bits, 8);
        };
        field(7, 4);           // the orientation: isometric
        field(0xffffffffu, 4); // no named view
        for (int i = 0; i < 3; ++i) real(0.0); // the origin
        // The standard isometric rotation, by rows, to the last bit as KOMPAS 17.1 computes it.
        for (const double v : {-0x1.e11f642522d1bp-1, 0x1.5e3a8748a0bf7p-2, 0.0, -0x1.df24174c2bf1dp-4, -0x1.491b7523c161cp-2,
                               0x1.e11f642522d1bp-1, 0x1.491b7523c161ep-2, 0x1.c41b7d167a81cp-1, 0x1.5e3a8748a0bf5p-2})
            real(v);
        real(0x1.139ce322b5845p+6); // 68.9…: the extent of the view as KOMPAS 17.1 opens a part
        real(0x1.5a6900584fbe5p+6); // 86.6…: 100·cos 30°
        real(1.0);                // scale
        real(3.0);
        field(0, 1);
        field(3, 4);
        field(1, 1);
        field(1, 1);
        field(0, 9);
        field(50, 4);
        field(50, 4);
        field(0, 22);
        field(100, 8);
        field(100, 8);
        field(0, 9);
        field(1, 1);
        field(0, 8);
        field(1, 4);
        for (int i = 0; i < 3; ++i) real(0.0); // a frame: its origin
        for (int i = 0; i < 9; ++i) real(i % 4 == 0 ? 1.0 : 0.0); // and identity axes
        field(1, 4);
        field(1999, 2);
        return;
    }
    case KompasServiceRecord::UserSettings:
        field(8, 8);
        for (const auto& [index, value] : std::vector<std::pair<quint64, quint64>>{
                 {1, 0x040ece02}, {2, 0xb31b5de4}, {3, 0xc92be9ce}, {4, 0xffffffff}, {5, 0xd906ea07}, {7, 0}, {8, 0}, {6, 0xc0a11675}}) {
            field(index, 4);
            field(value, 4);
        }
        return;
    }
    throw std::runtime_error("record");
}

} // namespace

bool encodeKompasServiceRecord(KompasServiceRecord record, quint32 applicationVersion,
                               QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (record == KompasServiceRecord::ApplicationVersion && applicationVersion != 0x11001011) {
        error = QObject::tr("Служебная запись КОМПАС: поддержана только версия приложения 0x11001011.");
        return false;
    }
    try {
        Writer w;
        layout(record, [&](quint64 value, int width) {
            if (width > 8) {
                if (value) throw std::runtime_error("wide");
                w.zeros(width);
            } else {
                w.number(value, width);
            }
        }, applicationVersion);
        bytes = std::move(w.bytes);
        return true;
    } catch (const std::exception&) {
        error = QObject::tr("Неизвестная служебная запись КОМПАС.");
        return false;
    }
}

bool decodeKompasServiceRecord(KompasServiceRecord record, const QByteArray& bytes,
                               quint32& applicationVersion, QString& error) {
    error.clear();
    applicationVersion = 0;
    try {
        Reader r{bytes};
        quint64 version = 0;
        if (record == KompasServiceRecord::ApplicationVersion) {
            version = r.number(4);
            if (version != 0x11001011) throw std::runtime_error("version");
        } else {
            layout(record, [&](quint64 value, int width) {
                if (width > 8)
                    for (int i = 0; i < width; ++i) r.expect(0, 1);
                else
                    r.expect(value, width);
            }, 0);
        }
        r.end();
        applicationVersion = quint32(version);
        return true;
    } catch (const std::exception&) {
        error = QObject::tr("Служебная запись КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

bool encodeKompasLayers(const std::vector<KompasLayer>& layers, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (layers.size() != 1) {
        error = QObject::tr("Таблица слоёв КОМПАС: поддержан один слой.");
        return false;
    }
    Writer w;
    w.number(1, 1);                      // version
    w.number(quint64(layers.size()), 8); // count
    for (const auto& layer : layers) {
        if (layer.name.isEmpty() || layer.name.size() > 65536 || layer.color > 0xffffff) {
            error = QObject::tr("Недопустимый слой КОМПАС.");
            return false;
        }
        for (const auto value : layer.material)
            if (value > 100) {
                error = QObject::tr("Параметры материала слоя КОМПАС должны быть от 0 до 100.");
                return false;
            }
        newObject(w, 0x5347);
        w.number(0, 4); // the layer's number: the system layer is 0
        w.number(8, 1); // a native state byte, 8 in every sample
        w.number(layer.color, 4);
        w.string(layer.name);
        w.zeros(5);
        w.number(1, 1); // two native flags, set in every sample
        w.number(1, 1);
        for (const auto value : layer.material) w.number(value, 1);
        w.zeros(16);
        w.number(1, 1); // a native flag, set in every sample
        w.zeros(24);
    }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasLayers(const QByteArray& bytes, std::vector<KompasLayer>& layers, QString& error) {
    layers.clear();
    error.clear();
    try {
        Reader r{bytes};
        r.expect(1, 1);
        const auto count = r.number(8);
        if (count != 1) throw std::runtime_error("count");
        KompasLayer layer;
        expectNewObject(r, 0x5347);
        r.expect(0, 4);
        r.expect(8, 1);
        layer.color = quint32(r.number(4));
        layer.name = r.string();
        for (int i = 0; i < 5; ++i) r.expect(0, 1);
        r.expect(1, 1);
        r.expect(1, 1);
        for (auto& value : layer.material) {
            value = quint8(r.number(1));
            if (value > 100) throw std::runtime_error("material");
        }
        for (int i = 0; i < 16; ++i) r.expect(0, 1);
        r.expect(1, 1);
        for (int i = 0; i < 24; ++i) r.expect(0, 1);
        r.end();
        if (layer.color > 0xffffff || layer.name.isEmpty()) throw std::runtime_error("layer");
        layers.push_back(std::move(layer));
        return true;
    } catch (const std::exception&) {
        layers.clear();
        error = QObject::tr("Таблица слоёв КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

namespace {

constexpr const char* kStringNature = "V9838B815F57644818A63FC39DB304252";
constexpr const char* kNoUnit = "VBB4733768E3C438997F2A7AC9182FBF0";

struct StandardProperty {
    int id;
    const char* name;    // MetaInfo name
    const char* comment; // MetaInfo comment, the definition's display name ("" when none)
    const char* type;    // MetaInfo typeValue
    const char* nature;  // the definition's source key, MetaInfo natureId
    const char* unit;    // the definition's value key; MetaInfo unitId for numbers
    quint64 nativeType;  // 0 integer, 1 real, 2 string
    double nativeLimit;
    quint32 nativeRule;
    std::vector<const char*> variants;
};

// In the order of the MetaInfo descriptions.
const std::vector<StandardProperty>& standardProperties() {
    static const std::vector<StandardProperty> table{
        {4, "Обозначение", "", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {5, "Наименование", "", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {8, "Масса", "", "double", "V16F0ACEB123048408CFC1292992D9C44", "VD53586643AE74C38A1BDF03D34991850", 1, 5e12, 3, {}},
        {9, "Материал", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {10, "Плотность", "", "double", "V19FC3778AF154EB79CAEFBF05ECA64BE", "V0E6F6906E36F473797089A7D9DEC8E29", 1, 1e9, 3, {}},
        {6, "Количество", "", "integer", kStringNature, kNoUnit, 0, 2147483647, 3, {}},
        {11, "Автор", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {12, "Организация", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {13, "Комментарий", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {14, "Тип объекта", "", "string", kStringNature, kNoUnit, 2, 260, 1,
         {"Сборочная единица", "Деталь", "Стандартное изделие", "Компонент из библиотеки", "Тело", "Локальная деталь",
          "Деталь-заготовка", "Вид чертежа", "Вставка вида", "Вставка фрагмента", "Макроэлемент 2D", "Чертеж", "Фрагмент",
          "Спецификация", "Текстовый документ"}},
        {15, "Позиция", "", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {16, "Полное имя файла", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {17, "Имя файла", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {18, "Создан", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {19, "Последнее изменение", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {20, "Раздел спецификации", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {21, "Разработал", "", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {22, "Проверил", "", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {23, "Утвердил", "", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {24, "Т. контр.", "Технологический контроль", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {25, "Н. контр.", "Нормоконтроль", "string", kStringNature, kNoUnit, 2, 260, 2, {}},
        {26, "Класс точности", "", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {37, "Знак неуказанной шероховатости", "Неуказанная шероховатость", "string", kStringNature, kNoUnit, 2, 260, 1,
         {"Шероховатость не задана", "Способ обработки не устанавливается", "С удалением слоя материала",
          "Без удаления слоя материала"}},
        {38, "Параметр неуказанной шероховатости", "Неуказанная шероховатость", "string", kStringNature, kNoUnit, 2, 260, 3, {}},
        {50, "Рассекать на разрезах", "", "string", kStringNature, kNoUnit, 2, 260, 0, {"Да", "Нет"}},
    };
    return table;
}

const StandardProperty& standardProperty(int id) {
    for (const auto& p : standardProperties())
        if (p.id == id) return p;
    throw std::runtime_error("property");
}

QString escaped(const QString& value) {
    QString out;
    for (const QChar c : value) {
        switch (c.unicode()) {
        case '&': out += QStringLiteral("&amp;"); break;
        case '<': out += QStringLiteral("&lt;"); break;
        case '>': out += QStringLiteral("&gt;"); break;
        case '"': out += QStringLiteral("&quot;"); break;
        default: out += c;
        }
    }
    return out;
}

// A mass as KOMPAS writes it: nine significant digits, 0 when not calculated.
QString massText(double kg) {
    char text[64];
    std::snprintf(text, sizeof text, "%.9g", kg);
    return QString::fromLatin1(text);
}

} // namespace

KompasPropertyDefinitions kompasStandardPropertyDefinitions() {
    KompasPropertyDefinitions definitions;
    for (const int id : {4, 5, 6, 9, 10, 8, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 37, 38, 50}) {
        const StandardProperty& p = standardProperty(id);
        KompasPropertyDefinition d;
        d.nativeType = p.nativeType;
        d.nativeLimit = p.nativeLimit;
        d.id = p.id;
        d.sourceKey = QString::fromLatin1(p.nature);
        d.valueKey = QString::fromLatin1(p.unit);
        d.displayName = QString::fromUtf8(p.comment);
        if (!p.variants.empty()) {
            std::vector<QString> choices;
            for (const char* v : p.variants) choices.push_back(QString::fromUtf8(v));
            d.choices = std::move(choices);
        }
        d.nativeRule = p.nativeRule;
        definitions.entries.push_back(std::move(d));
    }
    return definitions;
}

KompasPropertyTuning kompasStandardPropertyTuning() {
    KompasPropertyTuning tuning;
    const std::set<int> shownFirst{4, 5, 8}, shownSecond{5, 4, 9, 8};
    for (const int id : {4, 5, 6, 9, 10, 8, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 37, 38, 50})
        tuning.lists[0].push_back({double(id), shownFirst.count(id) > 0});
    for (const int id : {5, 4, 9, 8, 6, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 37, 38, 50})
        tuning.lists[1].push_back({double(id), shownSecond.count(id) > 0});
    return tuning;
}

bool encodeKompasMetaInfo(const KompasMetaInfo& info, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    const auto bad = [](const QString& v) { return v.size() > 65536 || v.contains(QChar(u'\0')); };
    bool invalid = bad(info.name) || bad(info.material) || !std::isfinite(info.massKg) || info.massKg < 0 ||
                   (info.designation && bad(*info.designation)) || (info.author && bad(*info.author)) ||
                   (info.organization && bad(*info.organization));
    for (const auto& body : info.bodies) invalid = invalid || bad(body.name) || bad(body.material) || !std::isfinite(body.massKg) || body.massKg < 0;
    if (invalid || info.bodies.size() > 65535) {
        error = QObject::tr("Недопустимые сведения MetaInfo КОМПАС.");
        return false;
    }
    QString x;
    const auto line = [&](int depth, const QString& text) { x += QString(depth, QChar(u'\t')) + text + QChar(u'\n'); };
    const auto property = [&](int depth, int id, const QString& value, int variant = -1) {
        line(depth, QStringLiteral("<property id=\"%1\" value=\"%2\"%3 modified=\"0\"/>")
                        .arg(id)
                        .arg(escaped(value))
                        .arg(variant < 0 ? QString() : QStringLiteral(" valueVariantId=\"%1\"").arg(variant)));
    };
    const auto variantName = [](int id, int variant) { return QString::fromUtf8(standardProperty(id).variants.at(std::size_t(variant))); };
    const auto documentProperties = [&](int depth) {
        line(depth, QStringLiteral("<properties>"));
        if (info.designation) property(depth + 1, 4, *info.designation);
        property(depth + 1, 5, info.name);
        property(depth + 1, 8, massText(info.massKg));
        property(depth + 1, 9, info.material);
        if (info.author) property(depth + 1, 11, *info.author);
        if (info.organization) property(depth + 1, 12, *info.organization);
        if (info.assembly) property(depth + 1, 14, variantName(14, 0), 0); // Сборочная единица
        else property(depth + 1, 14, variantName(14, 1), 1);               // Деталь
        property(depth + 1, 26, QStringLiteral("c"));
        property(depth + 1, 37, variantName(37, 0), 0); // Шероховатость не задана
        property(depth + 1, 50, variantName(50, 0), 0); // Да
        line(depth, QStringLiteral("</properties>"));
    };
    line(0, QStringLiteral("<?xml version=\"1.0\" encoding=\"utf-16\"?>"));
    line(0, QStringLiteral("<document baseEmbodiment=\"0\" currentEmbodiment=\"0\" modified=\"0\">"));
    line(1, QStringLiteral("<descriptions>"));
    line(2, QStringLiteral("<propertyDescriptions>"));
    for (const auto& p : standardProperties()) {
        QString head = QStringLiteral("<propertyDescription id=\"%1\" name=\"%2\" typeValue=\"%3\"")
                           .arg(p.id)
                           .arg(escaped(QString::fromUtf8(p.name)))
                           .arg(QString::fromLatin1(p.type));
        if (*p.comment) head += QStringLiteral(" comment=\"%1\"").arg(escaped(QString::fromUtf8(p.comment)));
        head += QStringLiteral(" natureId=\"%1\"").arg(QString::fromLatin1(p.nature));
        if (std::string(p.type) != "string") head += QStringLiteral(" unitId=\"%1\"").arg(QString::fromLatin1(p.unit));
        if (p.variants.empty()) {
            line(3, head + QStringLiteral("/>"));
            continue;
        }
        line(3, head + QStringLiteral(">"));
        for (std::size_t v = 0; v < p.variants.size(); ++v)
            line(4, QStringLiteral("<valueVariant id=\"%1\" value=\"%2\"/>").arg(v).arg(escaped(QString::fromUtf8(p.variants[v]))));
        line(3, QStringLiteral("</propertyDescription>"));
    }
    line(2, QStringLiteral("</propertyDescriptions>"));
    line(1, QStringLiteral("</descriptions>"));
    documentProperties(1);
    line(1, QStringLiteral("<objects>"));
    line(2, QStringLiteral("<object id=\"0\" type=\"embodiment\" modified=\"0\">"));
    documentProperties(3);
    if (!info.bodies.empty()) {
        line(3, QStringLiteral("<objects>"));
        for (std::size_t i = 0; i < info.bodies.size(); ++i) {
            const auto& body = info.bodies[i];
            if (info.assembly)
                line(4, QStringLiteral("<object id=\"%1\" type=\"component\" relSource=\"%2\" absSource=\"%3\" included=\"1\" modified=\"0\">")
                            .arg(i + 1)
                            .arg(escaped(body.relativeSource), escaped(body.absoluteSource)));
            else
                line(4, QStringLiteral("<object id=\"%1\" type=\"component\" modified=\"0\">").arg(i + 1));
            line(5, QStringLiteral("<properties>"));
            if (info.assembly && body.designation) property(6, 4, *body.designation);
            property(6, 5, body.name);
            property(6, 8, massText(body.massKg));
            property(6, 9, body.material);
            if (info.assembly && body.author) property(6, 11, *body.author);
            if (info.assembly && body.organization) property(6, 12, *body.organization);
            if (info.assembly) property(6, 14, variantName(14, 1), 1); // Деталь
            else property(6, 14, variantName(14, 4), 4);               // Тело
            property(6, 26, QStringLiteral("c"));
            property(6, 50, variantName(50, 0), 0);
            line(5, QStringLiteral("</properties>"));
            line(4, QStringLiteral("</object>"));
        }
        line(3, QStringLiteral("</objects>"));
    }
    line(2, QStringLiteral("</object>"));
    line(1, QStringLiteral("</objects>"));
    line(0, QStringLiteral("</document>"));
    bytes.reserve(2 + 2 * x.size());
    bytes.append(char(0xfe));
    bytes.append(char(0xff));
    for (const QChar c : x) {
        bytes.append(char(c.unicode() >> 8));
        bytes.append(char(c.unicode() & 0xff));
    }
    return true;
}

bool encodeKompasMetaInfoLinks(const std::vector<quint32>& bodyNumbers, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (bodyNumbers.size() > 65535 || std::find(bodyNumbers.begin(), bodyNumbers.end(), 0u) != bodyNumbers.end()) {
        error = QObject::tr("Недопустимые связи MetaInfo КОМПАС.");
        return false;
    }
    Writer w;
    w.number(quint64(bodyNumbers.size()) + 1, 4);
    // The embodiment's entry: the same twenty bytes in every sample (its field roles are not known).
    w.number(0, 5);
    w.number(0x0a3c, 2);
    w.number(0, 12);
    w.number(1, 1);
    for (const quint32 number : bodyNumbers) {
        w.number(0, 2);
        w.number(0x54, 1); // 'T': a body (тело)
        w.number(number, 4);
    }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasMetaInfoLinks(const QByteArray& bytes, std::vector<quint32>& bodyNumbers, QString& error) {
    bodyNumbers.clear();
    error.clear();
    try {
        Reader r{bytes};
        const auto count = r.number(4);
        if (count < 1 || count > 65536) throw std::runtime_error("count");
        r.expect(0, 5);
        r.expect(0x0a3c, 2);
        r.expect(0, 12);
        r.expect(1, 1);
        for (quint64 i = 1; i < count; ++i) {
            r.expect(0, 2);
            r.expect(0x54, 1);
            const auto number = r.number(4);
            if (!number) throw std::runtime_error("number");
            bodyNumbers.push_back(quint32(number));
        }
        r.end();
        return true;
    } catch (const std::exception&) {
        bodyNumbers.clear();
        error = QObject::tr("Связи MetaInfo КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

bool encodeKompasDocumentDates(const KompasDocumentDates& dates, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    Writer w;
    for (const QDateTime& t : {dates.created, dates.modified}) {
        const QDate d = t.date();
        const QTime c = t.time();
        if (!t.isValid() || d.year() < 1980 || d.year() > 2107) {
            error = QObject::tr("Дата документа КОМПАС вне 1980–2107.");
            return false;
        }
        w.number(quint64(((d.year() - 1980) << 9) | (d.month() << 5) | d.day()), 2);
        w.number(quint64((c.hour() << 11) | (c.minute() << 5) | (c.second() / 2)), 2);
    }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasDocumentDates(const QByteArray& bytes, KompasDocumentDates& dates, QString& error) {
    dates = {};
    error.clear();
    try {
        Reader r{bytes};
        for (QDateTime* t : {&dates.created, &dates.modified}) {
            const auto day = r.number(2), time = r.number(2);
            const QDate d(int(day >> 9) + 1980, int((day >> 5) & 15), int(day & 31));
            const QTime c(int(time >> 11), int((time >> 5) & 63), int(time & 31) * 2);
            if (!d.isValid() || !c.isValid()) throw std::runtime_error("date");
            *t = QDateTime(d, c);
        }
        r.end();
        return true;
    } catch (const std::exception&) {
        dates = {};
        error = QObject::tr("Даты документа КОМПАС не прочитаны.");
        return false;
    }
}

// Each author: the name, a set flag, whether an organization follows, eleven empty bytes, the organization.
bool encodeKompasDocumentAuthors(const std::vector<KompasDocumentAuthor>& authors, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (authors.empty() || authors.size() > 4096) {
        error = QObject::tr("Сведения об авторах КОМПАС: от 1 до 4096 записей.");
        return false;
    }
    Writer w;
    for (const auto& author : authors) {
        if (author.name.isEmpty() || author.name.size() > 65536 || (author.organization && author.organization->size() > 65536)) {
            error = QObject::tr("Недопустимый автор документа КОМПАС.");
            return false;
        }
        w.string(author.name);
        w.number(1, 1);
        w.number(author.organization ? 1 : 0, 1);
        w.zeros(11);
        if (author.organization) w.string(*author.organization);
    }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasDocumentAuthors(const QByteArray& bytes, std::vector<KompasDocumentAuthor>& authors, QString& error) {
    authors.clear();
    error.clear();
    try {
        Reader r{bytes};
        while (r.at < bytes.size()) {
            KompasDocumentAuthor author;
            author.name = r.string();
            r.expect(1, 1);
            const auto organization = r.number(1);
            if (organization > 1 || author.name.isEmpty()) throw std::runtime_error("author");
            for (int i = 0; i < 11; ++i) r.expect(0, 1);
            if (organization) author.organization = r.string();
            authors.push_back(std::move(author));
        }
        if (authors.empty()) throw std::runtime_error("empty");
        return true;
    } catch (const std::exception&) {
        authors.clear();
        error = QObject::tr("Сведения об авторах КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

bool encodeKompasModelCounters(const KompasModelCounters& counters, KompasModelCounterRecords& records, QString& error) {
    records = {};
    error.clear();
    if (!counters.firstBodyShell || counters.firstBodyShell > 65535 || !counters.lastObjectId || counters.lastObjectId > 65535 ||
        counters.firstBodyShell > counters.lastObjectId || !counters.layoutCounter || counters.layoutCounter > 0xffffffffu - 8) {
        error = QObject::tr("Недопустимые счётчики модели КОМПАС.");
        return false;
    }
    Writer shell, last, layout, instances;
    shell.number(counters.firstBodyShell, 4);
    last.number(counters.lastObjectId, 4);
    layout.number(1, 1);
    layout.number(0xffffffffu, 4);
    layout.number(1, 1);
    layout.number(counters.layoutCounter, 4);
    layout.number(0, 1);
    layout.number(1, 1);
    layout.zeros(6);
    instances.number(quint64(counters.layoutCounter) + 8, 4);
    records = {shell.bytes, last.bytes, layout.bytes, instances.bytes};
    return true;
}

bool decodeKompasModelCounters(const KompasModelCounterRecords& records, KompasModelCounters& counters, QString& error) {
    counters = {};
    error.clear();
    try {
        Reader shell{records.firstBodyShell}, last{records.lastObjectId}, layout{records.layout}, instances{records.layoutInstances};
        counters.firstBodyShell = quint32(shell.number(4));
        counters.lastObjectId = quint32(last.number(4));
        layout.expect(1, 1);
        layout.expect(0xffffffffu, 4);
        layout.expect(1, 1);
        counters.layoutCounter = quint32(layout.number(4));
        layout.expect(0, 1);
        layout.expect(1, 1);
        for (int i = 0; i < 6; ++i) layout.expect(0, 1);
        if (instances.number(4) != quint64(counters.layoutCounter) + 8) throw std::runtime_error("instances");
        shell.end();
        last.end();
        layout.end();
        instances.end();
        return true;
    } catch (const std::exception&) {
        counters = {};
        error = QObject::tr("Счётчики модели КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

std::vector<KompasRepresentation> kompasStandardRepresentations(double firstKey) {
    return {{firstKey, 0, QStringLiteral("Полный")},
            {firstKey + 100, 2, QStringLiteral("Пустой")},
            {firstKey + 200, 10, QStringLiteral("Упрощенный")},
            {firstKey + 300, 8, QStringLiteral("Габарит")}};
}

// Each: an object of native class 0x3759, its key, kind, a null reference, 24 empty bytes, the name, then an
// empty field, a set flag and an empty field; the list closes with an empty field.
bool encodeKompasRepresentations(const std::vector<KompasRepresentation>& list, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (list.empty() || list.size() > 1024) {
        error = QObject::tr("Представления документа КОМПАС: от 1 до 1024.");
        return false;
    }
    Writer w;
    w.number(1, 1);
    w.number(list.size(), 8);
    for (const auto& r : list) {
        if (!std::isfinite(r.key) || r.name.isEmpty() || r.name.size() > 65536) {
            error = QObject::tr("Недопустимое представление документа КОМПАС.");
            return false;
        }
        newObject(w, 0x3759);
        quint64 bits;
        std::memcpy(&bits, &r.key, sizeof bits);
        w.number(bits, 8);
        w.number(r.kind, 4);
        w.number(0xffffffffu, 4);
        w.zeros(24);
        w.string(r.name);
        w.number(0, 4);
        w.number(1, 1);
        w.number(0, 8);
    }
    w.number(0, 4); // the list's closing field
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasRepresentations(const QByteArray& bytes, std::vector<KompasRepresentation>& list, QString& error) {
    list.clear();
    error.clear();
    try {
        Reader r{bytes};
        r.expect(1, 1);
        const auto count = r.number(8);
        if (!count || count > 1024) throw std::runtime_error("count");
        for (quint64 i = 0; i < count; ++i) {
            KompasRepresentation item;
            expectNewObject(r, 0x3759);
            const quint64 bits = r.number(8);
            std::memcpy(&item.key, &bits, sizeof bits);
            item.kind = quint32(r.number(4));
            r.expect(0xffffffffu, 4);
            for (int k = 0; k < 24; ++k) r.expect(0, 1);
            item.name = r.string();
            r.expect(0, 4);
            r.expect(1, 1);
            r.expect(0, 8);
            if (!std::isfinite(item.key) || item.name.isEmpty()) throw std::runtime_error("item");
            list.push_back(std::move(item));
        }
        r.expect(0, 4);
        r.end();
        return true;
    } catch (const std::exception&) {
        list.clear();
        error = QObject::tr("Представления документа КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

namespace {
const std::vector<std::pair<quint32, quint32>> kUserSettings{
    {1, 0x040ece02}, {2, 0xb31b5de4}, {3, 0xc92be9ce}, {4, 0xffffffff}, {5, 0xd906ea07}, {7, 0}, {8, 0}, {6, 0xc0a11675}};
}

bool encodeKompasDesignationRecord(const QString& designation, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (designation.size() > 65536 || designation.contains(QChar(u'\0'))) {
        error = QObject::tr("Недопустимое обозначение документа КОМПАС.");
        return false;
    }
    Writer w;
    w.number(1, 8);
    w.string(designation);
    for (const char separator : {'-', '.'}) {
        w.number(quint8(separator), 2);
        w.number(0, 4);
    }
    w.number(' ', 2);
    w.zeros(12);
    w.number(1, 2);
    w.number(kUserSettings.size(), 8);
    for (const auto& [index, value] : kUserSettings) {
        w.number(index, 4);
        w.number(value, 4);
    }
    w.number(0, 8);
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasDesignationRecord(const QByteArray& bytes, QString& designation, QString& error) {
    designation.clear();
    error.clear();
    try {
        Reader r{bytes};
        r.expect(1, 8);
        designation = r.string();
        for (const char separator : {'-', '.'}) {
            r.expect(quint8(separator), 2);
            r.expect(0, 4);
        }
        r.expect(' ', 2);
        for (int i = 0; i < 12; ++i) r.expect(0, 1);
        r.expect(1, 2);
        r.expect(kUserSettings.size(), 8);
        for (const auto& [index, value] : kUserSettings) {
            r.expect(index, 4);
            r.expect(value, 4);
        }
        r.expect(0, 8);
        r.end();
        return true;
    } catch (const std::exception&) {
        designation.clear();
        error = QObject::tr("Запись обозначения КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

} // namespace cadnext::gui
