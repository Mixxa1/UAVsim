#include "cadnext/gui/NativeKompasProperties.hpp"

#include <QObject>

#include <cmath>
#include <cstring>
#include <set>
#include <stdexcept>

namespace cadnext::gui {
namespace {

constexpr quint64 kMaxProperties = 65536;
constexpr qsizetype kMaxRecordBytes = 64 * 1024 * 1024;

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("Truncated property record");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 expected, int width) {
        if (number(width) != expected) throw std::runtime_error("Unsupported property record layout");
    }
    quint64 count(quint64 width = 8) {
        const auto value = number(int(width));
        if (value > kMaxProperties) throw std::runtime_error("Oversized property list");
        return value;
    }
    double real() {
        const auto bits = number(8);
        double value;
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite property number");
        return value;
    }
    QString string() {
        const auto size = count(4);
        if (size * 2 > quint64(bytes.size() - at)) throw std::runtime_error("Truncated property string");
        QString value;
        value.reserve(qsizetype(size));
        for (quint64 i = 0; i < size; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
    void finish() const {
        if (at != bytes.size()) throw std::runtime_error("Trailing property record data");
    }
};

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        if (bytes.size() > kMaxRecordBytes - width) throw std::runtime_error("Oversized property record");
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void real(double value) {
        quint64 bits;
        std::memcpy(&bits, &value, sizeof(bits));
        number(bits, 8);
    }
    void string(const QString& value) {
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
};

void validateId(double id) {
    if (!std::isfinite(id) || !(id > 0)) throw std::runtime_error("Invalid property ID");
}

void validateString(const QString& value) {
    if (value.size() > qsizetype(kMaxProperties)) throw std::runtime_error("Oversized property string");
}

void validate(const KompasPropertyDefinitions& definitions) {
    if (definitions.entries.size() > kMaxProperties) throw std::runtime_error("Oversized property list");
    std::set<double> ids;
    for (const auto& definition : definitions.entries) {
        validateId(definition.id);
        if (!ids.insert(definition.id).second) throw std::runtime_error("Duplicate property ID");
        if (definition.nativeType > 2 || definition.nativeRule > 3)
            throw std::runtime_error("Unsupported property scalar profile");
        if (!std::isfinite(definition.nativeLimit) || definition.nativeLimit < 0)
            throw std::runtime_error("Invalid property limit");
        validateString(definition.sourceKey); validateString(definition.valueKey);
        validateString(definition.displayName);
        if (definition.choices) {
            if (definition.choices->size() > kMaxProperties) throw std::runtime_error("Oversized property choices");
            for (const auto& choice : *definition.choices) validateString(choice);
        }
    }
}

void validate(const KompasPropertyTuning& tuning) {
    for (const auto& list : tuning.lists) {
        if (list.size() > kMaxProperties) throw std::runtime_error("Oversized property tuning list");
        std::set<double> ids;
        for (const auto& entry : list) {
            validateId(entry.id);
            if (!ids.insert(entry.id).second) throw std::runtime_error("Duplicate property tuning ID");
        }
    }
}

QString failure(const std::exception& error) {
    return QObject::tr("Каталог свойств КОМПАС: %1").arg(QString::fromUtf8(error.what()));
}

void readDefinition(Reader& r, KompasPropertyDefinition& definition) {
    // A supported inline definition, class 0x7343; no global object alias.
    r.expect(1, 1); r.expect(1, 1); r.expect(0, 1); r.expect(0x7343, 2);
    r.expect(0, 4); definition.nativeType = r.number(8); r.expect(0, 4);
    definition.nativeLimit = r.real(); definition.id = r.real();
    definition.sourceKey = r.string(); definition.valueKey = r.string();
    r.expect(4, 4); definition.displayName = r.string();
    const auto variant = r.number(2);
    if (variant == 0x2008) { // one-dimensional array of UTF-16 strings
        r.expect(1, 4);
        const auto count = r.count(4);
        definition.choices.emplace();
        for (quint64 i = 0; i < count; ++i) definition.choices->push_back(r.string());
    } else if (variant != 0) throw std::runtime_error("Unsupported property choice variant");
    r.expect(4, 4); definition.nativeRule = quint32(r.number(4));
    r.expect(0, 2); r.expect(0, 4); r.expect(8, 8);
}

void writeDefinition(Writer& w, const KompasPropertyDefinition& definition) {
    w.number(1, 1); w.number(1, 1); w.number(0, 1); w.number(0x7343, 2);
    w.number(0, 4); w.number(definition.nativeType, 8); w.number(0, 4);
    w.real(definition.nativeLimit); w.real(definition.id);
    w.string(definition.sourceKey); w.string(definition.valueKey);
    w.number(4, 4); w.string(definition.displayName);
    if (definition.choices) {
        w.number(0x2008, 2); w.number(1, 4); w.number(definition.choices->size(), 4);
        for (const auto& choice : *definition.choices) w.string(choice);
    } else w.number(0, 2);
    w.number(4, 4); w.number(definition.nativeRule, 4);
    w.number(0, 2); w.number(0, 4); w.number(8, 8);
}

} // namespace

bool decodeKompasPropertyDefinitions(const QByteArray& bytes,
                                     KompasPropertyDefinitions& definitions,
                                     QString& error) {
    definitions = {}; error.clear(); KompasPropertyDefinitions staged; Reader r{bytes};
    try {
        if (bytes.size() > kMaxRecordBytes) throw std::runtime_error("Oversized property record");
        r.expect(1, 1); const auto count = r.count();
        for (quint64 i = 0; i < count; ++i) {
            KompasPropertyDefinition definition; readDefinition(r, definition);
            staged.entries.push_back(std::move(definition));
        }
        r.expect(1, 1); r.expect(0, 8); r.finish(); validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    definitions = std::move(staged); return true;
}

bool encodeKompasPropertyDefinitions(const KompasPropertyDefinitions& definitions,
                                     QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(definitions); w.number(1, 1); w.number(definitions.entries.size(), 8);
        for (const auto& definition : definitions.entries) writeDefinition(w, definition);
        w.number(1, 1); w.number(0, 8);
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes); return true;
}

bool decodeKompasPropertyTuning(const QByteArray& bytes, KompasPropertyTuning& tuning,
                                QString& error) {
    tuning = {}; error.clear(); KompasPropertyTuning staged; Reader r{bytes};
    try {
        if (bytes.size() > kMaxRecordBytes) throw std::runtime_error("Oversized property record");
        for (auto& list : staged.lists) {
            const auto count = r.count();
            for (quint64 i = 0; i < count; ++i) {
                const auto id = r.real(); const auto enabled = r.number(1);
                if (enabled > 1) throw std::runtime_error("Invalid property tuning flag");
                list.push_back({id, enabled != 0});
            }
        }
        r.finish(); validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    tuning = std::move(staged); return true;
}

bool encodeKompasPropertyTuning(const KompasPropertyTuning& tuning,
                                QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(tuning);
        for (const auto& list : tuning.lists) {
            w.number(list.size(), 8);
            for (const auto& entry : list) { w.real(entry.id); w.number(entry.enabled, 1); }
        }
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes); return true;
}

bool validateKompasPropertyReferences(const KompasPropertyDefinitions& definitions,
                                      const KompasPropertyTuning& tuning,
                                      QString& error) {
    error.clear();
    try {
        validate(definitions); validate(tuning); std::set<double> ids;
        for (const auto& entry : definitions.entries) ids.insert(entry.id);
        for (const auto& list : tuning.lists)
            for (const auto& entry : list)
                if (!ids.count(entry.id)) throw std::runtime_error("Property tuning references an undefined ID");
    } catch (const std::exception& e) { error = failure(e); return false; }
    return true;
}

} // namespace cadnext::gui
