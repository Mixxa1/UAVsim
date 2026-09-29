#include "cadnext/gui/NativeParasolidXt.hpp"

#include <QHash>
#include <QObject>
#include <QSet>

#include <algorithm>
#include <bit>
#include <cmath>
#include <limits>

namespace cadnext::gui {
namespace {

struct XtField {
    QByteArray name;
    char type = 0;
    quint32 count = 1;
    bool variable = false;
};

quint16 be16(const QByteArray& data, qsizetype at) {
    const auto* p = reinterpret_cast<const unsigned char*>(data.constData() + at);
    return quint16(p[0]) << 8 | quint16(p[1]);
}

quint32 be32(const QByteArray& data, qsizetype at) {
    return quint32(be16(data, at)) << 16 | be16(data, at + 2);
}

double beDouble(const QByteArray& data, qsizetype at) {
    const quint64 bits = quint64(be32(data, at)) << 32 | be32(data, at + 4);
    return std::bit_cast<double>(bits);
}

const char* baseFields(quint16 type) {
    // Effective fields in the public XT base schema 13006 (Siemens JT Annex E).
    // The transmitted version changes these through C/D/I/A edit instructions.
    switch (type) {
    case 101: return "assembly:p attribute:p body:p transform:p surface:p curve:p point:p alive:l attrib_def:p highest_id:d current_id:d";
    // ASSEMBLY and INSTANCE as the XT Format Reference lists them; a part file with an assembly
    // (Canard_Halves_1_Machineing_Asm.x_t from SOLIDWORKS 2016) transmits both unchanged (255).
    case 10: return "highest_node_id:d attributes_groups:p attribute_chains:p list:p surface:p curve:p point:p key:p res_size:f res_linear:f ref_instance:p next:p previous:p state:u owner:p type:u sub_instance:p";
    case 11: return "node_id:d attributes_groups:p type:u part:p transform:p assembly:p next_in_part:p prev_in_part:p next_of_part:p prev_of_part:p";
    case 12: return "highest_node_id:d attributes_groups:p attribute_chains:p surface:p curve:p point:p key:p res_size:f res_linear:f ref_instance:p next:p previous:p state:u owner:p body_type:u nom_geom_state:u shell:p boundary_surface:p boundary_curve:p boundary_point:p region:p edge:p vertex:p";
    case 80: return "next:p identifier:p type_id:d actions:u8 field_names:p legal_owners:l14 fields:u*";
    case 79: return "String:c*";
    case 81: return "node_id:d definition:p owner:p next:p previous:p next_of_type:p previous_of_type:p fields:p*";
    // Two obsolete base fields are deleted by the embedded LIST schema in
    // the SOLIDWORKS 2018 samples. Their types are immaterial to transmission.
    case 70: return "node_id:d owner:p next:p previous:p legacy1:d list_length:d block_length:d legacy2:d list_block:p";
    case 74: return "n_entries:d next_block:p entries:p*";
    case 13: return "node_id:d attributes_groups:p body:p next:p face:p edge:p vertex:p region:p front_face:p";
    case 19: return "node_id:d attributes_groups:p body:p next:p previous:p shell:p type:c";
    case 14: return "node_id:d attributes_groups:p tolerance:f next:p previous:p loop:p shell:p surface:p sense:c next_on_surface:p previous_on_surface:p next_front:p previous_front:p front_shell:p";
    case 15: return "node_id:d attributes_groups:p fin:p face:p next:p";
    case 17: return "attributes_groups:p loop:p forward:p backward:p vertex:p other:p edge:p curve:p next_at_vx:p sense:c";
    case 18: return "node_id:d attributes_groups:p fin:p previous:p next:p point:p tolerance:f owner:p";
    case 16: return "node_id:d attributes_groups:p tolerance:f fin:p previous:p next:p curve:p next_on_curve:p previous_on_curve:p owner:p";
    case 29: return "node_id:d attributes_groups:p owner:p next:p previous:p pvec:v";
    case 30: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c pvec:v direction:v";
    case 31: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c centre:v normal:v x_axis:v radius:f";
    // The transmitted SW2018 ellipse puts sense before centre. Treating it
    // as centre-before-sense decodes a finite but absurd ~1e71 coordinate.
    case 32: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c centre:v normal:v x_axis:v major_radius:f minor_radius:f";
    case 38: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c surface:p2 chart:p start:p end:p";
    case 40: return "Base_parameter:f Base_scale:f Chart_count:d Chordal_error:f Angular_error:f Parameter_error:f2 Hvec:h*";
    case 41: return "type:c hvec:h*";
    case 45: return "vertices:f*";
    case 50: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c pvec:v normal:v x_axis:v";
    case 51: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c pvec:v axis:v radius:f x_axis:v";
    case 52: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c pvec:v axis:v radius:f sin_half_angle:f cos_half_angle:f x_axis:v";
    case 53: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c centre:v radius:f axis:v x_axis:v";
    case 54: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c centre:v axis:v major_radius:f minor_radius:f x_axis:v";
    case 56: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c blend_type:c surface:p2 spine:p range:f2 thumb_weight:f2 boundary:p2 start:p end:p";
    case 59: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c boundary:n blend:p";
    case 60: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c check:c true_offset:l surface:p offset:f scale:f";
    // Swept and spun surfaces, the SP-curve and the helical forms of B-geometry, as the XT Format
    // Reference lists them. SOLIDWORKS 2016-2017 parts and Onshape assemblies transmit all five
    // unchanged (255) against the base schema. Of the two helical forms the Reference gives
    // HELIX_CU_FORM a `point` and HELIX_SU_FORM a `gap`; the bytes of SOLIDWORKS 2016 threads (a nut and
    // a cap screw of the NIST MTC assembly) have it the other way round: the curve form reads
    // axis_pt, axis_dir, '+', turns [-1, 5.67], pitch 0.0007, unset, 1e-6; the surface form axis_pt,
    // axis_dir, a third vector, '+', turns [0, 20], pitch 0.0007, 1e-5.
    case 67: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c section:p sweep:v scale:f";
    case 68: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c profile:p base:v axis:v start:v end:v start_param:f end_param:f x_axis:v scale:f";
    case 137: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c surface:p b_curve:p original:p tolerance_to_original:f";
    case 163: return "axis_pt:v axis_dir:v hand:c turns:i pitch:f gap:f tol:f";
    case 184: return "axis_pt:v axis_dir:v point:v hand:c turns:i pitch:f tol:f";
    // Groups (NX keeps its features in them) and their members, as the XT Format Reference lists them.
    case 90: return "node_id:d attributes_groups:p owner:p next:p previous:p type:u first_member:p";
    case 91: return "dummy_node_id:d owning_group:p owner:p next:p previous:p next_member:p previous_member:p";
    case 82: return "values:d*";
    case 83: return "values:f*";
    case 84: return "values:c*";
    case 85: return "values:v*";
    case 86: return "values:v*";
    case 87: return "values:v*";
    case 88: return "values:d*";
    case 89: return "values:v*";
    case 98: return "values:w*";
    case 99: return "names:p*";
    case 100: return "node_id:d owner:p next:p previous:p rotation_matrix:f9 translation_vector:v scale:f flag:d perspective_vector:v";
    case 124: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c nurbs:p data:p";
    case 125: return "original_uint:i original_vint:i extended_uint:i extended_vint:i self_int:u original_u_start:c original_u_end:c original_v_start:c original_v_end:c extended_u_start:c extended_u_end:c extended_v_start:c extended_v_end:c analytic_form_type:c swept_form_type:c spun_form_type:c blend_form_type:c analytic_form:p swept_form:p spun_form:p blend_form:p";
    case 126: return "u_periodic:l v_periodic:l u_degree:n v_degree:n n_u_vertices:d n_v_vertices:d u_knot_type:u v_knot_type:u n_u_knots:d n_v_knots:d rational:l u_closed:l v_closed:l surface_form:u vertex_dim:n bspline_vertices:p u_knot_mult:p v_knot_mult:p u_knots:p v_knots:p";
    case 127: return "mult:n*";
    case 128: return "knots:f*";
    case 133: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c basis_curve:p point_1:v point_2:v parm_1:f parm_2:f";
    case 134: return "node_id:d attributes_groups:p owner:p next:p previous:p geometric_owner:p sense:c nurbs:p data:p";
    case 135: return "self_int:u analytic_form:p";
    case 136: return "degree:n n_vertices:d vertex_dim:n n_knots:d knot_type:u periodic:l closed:l rational:l curve_form:u bspline_vertices:p knot_mult:p knots:p";
    case 141: return "owner:p next:p previous:p shared_geometry:p";
    default: return nullptr;
    }
}

bool parseBaseFields(const char* spec, std::vector<XtField>& fields) {
    if (!spec) return false;
    for (const QByteArray& token : QByteArray(spec).split(' ')) {
        const qsizetype colon = token.indexOf(':');
        if (colon < 1 || colon + 1 >= token.size()) return false;
        XtField field;
        field.name = token.left(colon);
        field.type = token[colon + 1];
        const QByteArray suffix = token.mid(colon + 2);
        field.variable = suffix == "*";
        if (!suffix.isEmpty() && !field.variable) {
            bool ok = false;
            field.count = suffix.toUInt(&ok);
            if (!ok || field.count == 0 || field.count > 32) return false;
        }
        fields.push_back(std::move(field));
    }
    return !fields.empty();
}

// Unset values as Parasolid keeps them internally; a text file writes them as '?'.
constexpr qint32 kUnsetInteger = -32764;
constexpr double kUnsetReal = -3.14158e13;

// A source of XT fields in either physical encoding (XT Format Reference, "Physical layout"). The
// schema-driven loop reads every field through it, so the neutral binary stream inside a SOLIDWORKS
// part, a standalone .x_b and a text .x_t are decoded by one and the same logic, embedded schema
// edits included. Only the encoding differs:
//   binary — big-endian integers, IEEE doubles, pointer indices offset by one and split into a
//            pair above 32766, short strings as a length byte then the characters;
//   text   — every number in decimal followed by one space, chars and logicals as one character
//            with no space after, '?' for an unset value, itself with no space after (a whole vector is one '?'), short strings
//            as a length then the characters; newlines carry no meaning and are removed first.
class XtReader {
public:
    XtReader(const QByteArray& data, bool text) : data_(data), text_(text) {}

    bool isText() const { return text_; }
    qsizetype position() const { return at_; }
    void seek(qsizetype at) { at_ = at; }
    bool atEnd() const {
        qsizetype at = at_;
        if (text_)
            while (at < data_.size() && data_[at] == ' ') ++at;
        return at >= data_.size();
    }

    bool raw(qsizetype size, QByteArray& out) {
        if (size < 0 || size > data_.size() - at_) return false;
        out = data_.mid(at_, size);
        at_ += size;
        return true;
    }
    bool byte(quint8& value) {
        if (!text_) {
            if (at_ >= data_.size()) return false;
            value = quint8(data_[at_++]);
            return true;
        }
        qint64 number = 0;
        if (!integer(number) || number < 0 || number > 255) return false;
        value = quint8(number);
        return true;
    }
    // One character; in text, escapes are decoded here, so character fields (names, attribute
    // strings) and short strings share the same rules.
    bool character(char& value) {
        if (!text_) {
            if (at_ >= data_.size()) return false;
            value = data_[at_++];
            return true;
        }
        return textCharacter(value);
    }
    // A logical as the byte the binary form holds: 0 or 1.
    bool logical(char& value) {
        if (!text_) return character(value);
        char flag = 0;
        if (!character(flag) || (flag != 'T' && flag != 'F')) return false;
        value = flag == 'T' ? 1 : 0;
        return true;
    }
    bool i16(quint16& value) {
        if (!text_) {
            if (data_.size() - at_ < 2) return false;
            value = be16(data_, at_);
            at_ += 2;
            return true;
        }
        qint64 number = 0;
        if (!integer(number) || number < -32768 || number > 65535) return false;
        value = quint16(number);
        return true;
    }
    bool i32(quint32& value) {
        if (!text_) {
            if (data_.size() - at_ < 4) return false;
            value = be32(data_, at_);
            at_ += 4;
            return true;
        }
        qint64 number = 0;
        if (!integer(number) || number < std::numeric_limits<qint32>::min() || number > std::numeric_limits<quint32>::max()) return false;
        value = quint32(number);
        return true;
    }
    bool real(double& value) {
        if (!text_) {
            if (data_.size() - at_ < 8) return false;
            value = beDouble(data_, at_);
            at_ += 8;
            return true;
        }
        QByteArray word;
        if (!token(word)) return false;
        if (word == "?") {
            value = kUnsetReal;
            return true;
        }
        bool ok = false;
        value = word.toDouble(&ok);
        return ok;
    }
    // A vector: three reals, except that a text file writes an unset vector as a single '?' (no
    // space after it, as for any unset value).
    bool vector(std::array<double, 3>& value) {
        if (text_ && at_ < data_.size() && data_[at_] == '?') {
            ++at_;
            value = {kUnsetReal, kUnsetReal, kUnsetReal};
            return true;
        }
        return real(value[0]) && real(value[1]) && real(value[2]);
    }
    // Pointer indices and XT "positive integers": zero is a null pointer in both encodings.
    bool index(quint32& value) {
        if (!text_) return binaryIndex(value);
        qint64 number = 0;
        if (!integer(number) || number < 0 || number > std::numeric_limits<quint32>::max()) return false;
        value = quint32(number);
        return true;
    }
    bool shortString(QByteArray& text) {
        quint32 size = 0;
        if (!text_) {
            if (at_ >= data_.size()) return false;
            size = quint8(data_[at_++]);
            if (size > 128) return false;
            return raw(size, text);
        }
        qint64 number = 0;
        if (!integer(number) || number < 0 || number > 128) return false;
        text.clear();
        for (qint64 i = 0; i < number; ++i) {
            char c = 0;
            if (!textCharacter(c)) return false;
            text.append(c);
        }
        return true;
    }

private:
    bool token(QByteArray& word) {
        if (pendingSpaces_ != 0) return false;
        // The unset mark is one character with no space after it: files written by Parasolid have
        // "0 ?24 0" for an unset tolerance followed by a pointer, although the reference says only
        // that numbers are followed by a space.
        if (at_ < data_.size() && data_[at_] == '?') {
            ++at_;
            word = QByteArrayLiteral("?");
            return true;
        }
        const qsizetype start = at_;
        while (at_ < data_.size() && data_[at_] != ' ') ++at_;
        if (at_ == start) return false;
        word = data_.mid(start, at_ - start);
        if (at_ < data_.size()) ++at_; // the one separating space
        return true;
    }
    bool integer(qint64& value) {
        QByteArray word;
        if (!token(word)) return false;
        if (word == "?") {
            value = kUnsetInteger;
            return true;
        }
        bool ok = false;
        value = word.toLongLong(&ok);
        return ok;
    }
    // A text character with the escapes of Parasolid 12.1 and later: \0, \n, \r, \\, and the V14
    // space compression \9 for nine spaces. A declared length counts decoded characters, so the
    // spaces of one \9 are handed out one by one.
    bool textCharacter(char& value) {
        if (pendingSpaces_ > 0) {
            --pendingSpaces_;
            value = ' ';
            return true;
        }
        if (at_ >= data_.size()) return false;
        const char c = data_[at_++];
        if (c != '\\') {
            value = c;
            return true;
        }
        if (at_ >= data_.size()) return false;
        const char e = data_[at_++];
        if (e == '0') value = '\0';
        else if (e == 'n') value = '\n';
        else if (e == 'r') value = '\r';
        else if (e == '\\') value = '\\';
        else if (e == '9') { value = ' '; pendingSpaces_ = 8; }
        else return false;
        return true;
    }
    bool binaryIndex(quint32& value) {
        if (data_.size() - at_ < 2) return false;
        const quint16 first = be16(data_, at_);
        at_ += 2;
        if (first == 0) return false;
        if (first < 0x8000u) {
            value = first - 1;
            return true;
        }
        if (first == 0x8000u || data_.size() - at_ < 2) return false;
        const quint16 quotient = be16(data_, at_);
        at_ += 2;
        if (quotient == 0) return false;
        const quint64 expanded = quint64(quotient) * 32767u + (0x10000u - first) - 1u;
        if (expanded > std::numeric_limits<quint32>::max()) return false;
        value = quint32(expanded);
        return true;
    }

    const QByteArray& data_;
    bool text_;
    qsizetype at_ = 0;
    int pendingSpaces_ = 0;
};

bool fieldDefinition(XtReader& reader, XtField& field) {
    if (!reader.shortString(field.name) || field.name.isEmpty()) return false;
    quint16 pointerClass = 0;
    if (!reader.i16(pointerClass)) return false;
    quint32 encodedElements = 0;
    if (!reader.index(encodedElements) || encodedElements > 1024) return false;
    if (pointerClass != 0) {
        field.type = 'p';
    } else {
        QByteArray name;
        if (!reader.shortString(name) || name.size() != 1) return false;
        field.type = name[0];
    }
    // XT's n_elts is a positive integer with an offset encoding: zero is a
    // scalar, one denotes a variable array followed by xmt_code, and larger
    // values are the number of fixed elements. It is not a raw 16-bit count.
    if (encodedElements == 1) {
        char transmitted = 0;
        if (!reader.logical(transmitted) || transmitted != 1) return false;
        field.variable = true;
    } else {
        field.count = std::max<quint32>(1, encodedElements);
    }
    return true;
}

bool schemaFields(XtReader& reader, quint16 type, std::vector<XtField>& fields) {
    quint8 expected = 0;
    if (!reader.byte(expected)) return false;
    std::vector<XtField> base;
    const bool known = parseBaseFields(baseFields(type), base);
    if (expected == 0xffu) {
        if (!known) return false;
        fields = std::move(base);
        return true;
    }
    if (expected == 0 || expected > 128) return false;
    if (!known) {
        QByteArray name, description;
        if (!reader.shortString(name) || name.isEmpty() || !reader.shortString(description)) return false;
        for (quint8 i = 0; i < expected; ++i) {
            XtField field;
            if (!fieldDefinition(reader, field)) return false;
            fields.push_back(std::move(field));
        }
        return true;
    }
    qsizetype baseAt = 0;
    bool terminated = false;
    for (int step = 0; step < 256 && !reader.atEnd(); ++step) {
        char code = 0;
        if (!reader.character(code)) return false;
        if (code == 'Z') { terminated = true; break; }
        if (code == 'C') {
            if (baseAt >= qsizetype(base.size())) return false;
            fields.push_back(base[baseAt++]);
        } else if (code == 'D') {
            if (baseAt >= qsizetype(base.size())) return false;
            ++baseAt;
        } else if (code == 'I' || code == 'A') {
            XtField field;
            if (!fieldDefinition(reader, field)) return false;
            fields.push_back(std::move(field));
        } else {
            return false;
        }
        if (fields.size() > 128) return false;
    }
    return terminated && baseAt == qsizetype(base.size()) &&
           fields.size() == expected;
}

// What kind of transmit a header describes, and the size of its node table.
struct XtHeader {
    bool partition = false;
    QByteArray modeller;
    QByteArray schema;
    quint16 maxType = 0;
};

// The data header that follows the flag ("PS\0\0" in neutral binary, 'T' in text): the modeller
// identification, the schema key and, for files with an embedded schema, the size of the node table
// and the user-field size.
bool readXtHeader(XtReader& reader, XtHeader& header, QString& error) {
    const auto unsupported = [&](const QString& why) {
        error = why;
        return false;
    };
    if (reader.isText()) {
        char flag = 0;
        if (!reader.character(flag) || flag != 'T') return unsupported(QObject::tr("Текстовый поток Parasolid XT не начинается с флага T."));
    } else {
        QByteArray flag;
        if (!reader.raw(4, flag) || flag != QByteArray("PS\0\0", 4))
            return unsupported(QObject::tr("Поток Parasolid XT не в нейтральном двоичном формате."));
    }
    quint16 modelSize = 0;
    quint32 schemaSize = 0;
    if (reader.isText()) {
        quint32 size = 0;
        if (!reader.index(size) || size == 0 || size > 256) return unsupported(QObject::tr("Повреждён заголовок Parasolid XT."));
        modelSize = quint16(size);
    } else if (!reader.i16(modelSize) || modelSize == 0 || modelSize > 256) {
        return unsupported(QObject::tr("Повреждён заголовок Parasolid XT."));
    }
    if (!reader.raw(modelSize, header.modeller)) return unsupported(QObject::tr("Повреждён заголовок Parasolid XT."));
    if (reader.isText() ? !reader.index(schemaSize) : !reader.i32(schemaSize)) return unsupported(QObject::tr("Повреждён заголовок Parasolid XT."));
    if (schemaSize == 0 || schemaSize > 128 || !reader.raw(schemaSize, header.schema)) return unsupported(QObject::tr("Повреждён заголовок Parasolid XT."));
    header.partition = header.modeller.startsWith(": TRANSMIT FILE (partition)");
    if (!header.partition && !header.modeller.startsWith(": TRANSMIT FILE created by modeller version")) {
        return unsupported(QObject::tr("Это не файл передачи детали Parasolid: «%1».").arg(QString::fromLatin1(header.modeller)));
    }
    // SCH_<modeller>_<schema> before V14; SCH_<modeller>_<schema>_<base> from V14 on, where the file
    // carries its schema as edits against the base (V13's 13006), which this reader knows. A V13 key
    // such as SCH_1300123_13006 also ends in 13006 but has no embedded schema: two parts, not three.
    const QList<QByteArray> parts = header.schema.split('_');
    const auto numeric = [](const QByteArray& part) {
        if (part.isEmpty()) return false;
        for (char c : part)
            if (c < '0' || c > '9') return false;
        return true;
    };
    if (parts.size() < 3 || parts.front() != "SCH" || !std::all_of(parts.begin() + 1, parts.end(), numeric))
        return unsupported(QObject::tr("Неизвестный ключ схемы Parasolid XT: «%1».").arg(QString::fromLatin1(header.schema)));
    // Older files need the exact layout of their own schema, which is not in the file and which
    // CADNext does not have.
    if (parts.size() != 4 || parts.back() != "13006") {
        return unsupported(QObject::tr("Файл Parasolid XT со схемой %1 записан версией до V14 и не содержит описания своей схемы; "
                                       "у CADNext нет описания этой схемы. Сохраните модель из исходной системы заново (Parasolid V14 и новее) или в STEP.")
                               .arg(QString::fromLatin1(header.schema)));
    }
    quint32 userFields = 0;
    if (!reader.i16(header.maxType) || header.maxType == 0 || !reader.i32(userFields)) {
        return unsupported(QObject::tr("Повреждён заголовок Parasolid XT."));
    }
    // Non-zero user fields follow every visible node; the reader does not know their layout.
    if (userFields != 0) return unsupported(QObject::tr("Файл Parasolid XT содержит пользовательские поля (%1) — такой файл не поддержан.").arg(userFields));
    return true;
}

bool refersTo(const QHash<quint32, quint16>& types, quint32 index, quint16 expected) {
    return index == 0 || types.value(index, 0) == expected;
}

bool analyticGeometry(quint16 type) {
    return type == 30 || type == 31 || type == 32 || type == 38 ||
           type == 45 || (type >= 50 && type <= 54) ||
           type == 40 || type == 41 ||
           type == 56 || type == 59 || type == 60 || type == 67 ||
           type == 124 || type == 126 || type == 127 || type == 128 ||
           type == 133 || type == 134 || type == 136 || type == 137;
}

} // namespace

namespace {

bool decodeXtNodes(XtReader& reader, quint16 maxType, ParasolidXtTopology& topology, QString& error) {
    topology = {};
    QHash<quint16, std::vector<XtField>> schemas;
    QHash<quint32, quint16> types;
    QHash<quint32, std::array<double, 3>> points;
    // Attribute material, resolved once every node is read.
    struct RawAttribute {
        quint32 index = 0;
        quint32 definition = 0;
        quint32 owner = 0;
        std::vector<quint32> fields;
    };
    std::vector<RawAttribute> rawAttributes;
    QHash<quint32, quint32> definitionNames; // ATTRIB_DEF -> its identifier string node
    QHash<quint32, QByteArray> strings;      // string and character-values nodes
    QHash<quint32, std::vector<double>> realValues;
    bool terminated = false;
    quint16 lastType = 0;
    qsizetype lastStart = 0;
    while (!reader.atEnd()) {
        quint16 type = 0;
        lastStart = reader.position();
        if (!reader.i16(type)) break;
        lastType = type;
        if (type == 1) {
            quint32 indexValue = 0;
            terminated = reader.index(indexValue) && indexValue == 0 && reader.atEnd();
            break;
        }
        if (type == 0 || type > maxType || topology.nodeCount >= 2'000'000) break;
        if (!schemas.contains(type)) {
            std::vector<XtField> fields;
            if (!schemaFields(reader, type, fields)) break;
            schemas.insert(type, std::move(fields));
        }
        const auto& fields = schemas[type];
        quint32 variableCount = 0;
        if (!fields.empty() && fields.back().variable) {
            if (!reader.i32(variableCount)) break;
            if (variableCount > 1'000'000) break;
        }
        quint32 nodeIndex = 0;
        if (!reader.index(nodeIndex) || nodeIndex == 0 || types.contains(nodeIndex)) break;
        QHash<QByteArray, quint32> links;
        QHash<QByteArray, std::vector<quint32>> linkArrays;
        QHash<QByteArray, std::array<double, 3>> vectors;
        QHash<QByteArray, double> reals;
        QHash<QByteArray, quint32> integers;
        QHash<QByteArray, char> bytes;
        QHash<QByteArray, std::vector<double>> realArrays;
        QHash<QByteArray, std::vector<quint32>> integerArrays;
        std::array<double, 3> position{};
        bool hasPosition = false;
        double edgeTolerance = std::numeric_limits<double>::quiet_NaN();
        char sense = 0;
        QByteArray text;
        std::vector<double> values;
        ParasolidXtTransform transform;
        quint8 kind = 0; // body_type of a BODY, type of an INSTANCE
        bool valid = true;
        for (const XtField& field : fields) {
            const quint32 count = field.variable ? variableCount : field.count;
            if (field.type == 'p') {
                // An attribute's value nodes are a variable array, kept whatever its length.
                const bool attributeFields = type == 81 && field.variable;
                const bool keepArray = attributeFields ? count <= 4096
                                                       : analyticGeometry(type) && count > 1 && count <= 16;
                std::vector<quint32> targets;
                if (keepArray) targets.reserve(count);
                for (quint32 i = 0; i < count; ++i) {
                    quint32 target = 0;
                    if (!reader.index(target)) { valid = false; break; }
                    if (count == 1 && !attributeFields) links.insert(field.name, target);
                    else if (keepArray)
                        targets.push_back(target);
                }
                if (valid && !targets.empty())
                    linkArrays.insert(field.name, std::move(targets));
            } else {
                // Every element read through the reader, whatever the encoding; then the same
                // selection of what the BRep builder needs as the binary-only decoder made.
                if (count > 1'000'000) { valid = false; break; }
                std::vector<double> reals64;
                std::vector<quint32> numbers;
                std::vector<char> characters;
                switch (field.type) {
                case 'f':
                    reals64.resize(count);
                    for (quint32 i = 0; i < count && valid; ++i) valid = reader.real(reals64[i]);
                    break;
                case 'v':
                case 'h':
                    reals64.resize(std::size_t(count) * 3);
                    for (quint32 i = 0; i < count && valid; ++i) {
                        std::array<double, 3> vector{};
                        valid = reader.vector(vector);
                        std::copy(vector.begin(), vector.end(), reals64.begin() + std::size_t(i) * 3);
                    }
                    break;
                case 'i':
                case 'b': {
                    const quint32 components = field.type == 'i' ? 2 : 6;
                    reals64.resize(std::size_t(count) * components);
                    for (std::size_t i = 0; i < reals64.size() && valid; ++i) valid = reader.real(reals64[i]);
                    break;
                }
                case 'd':
                    numbers.resize(count);
                    for (quint32 i = 0; i < count && valid; ++i) valid = reader.i32(numbers[i]);
                    break;
                case 'n':
                case 'w':
                    numbers.resize(count);
                    for (quint32 i = 0; i < count && valid; ++i) {
                        quint16 value = 0;
                        valid = reader.i16(value);
                        numbers[i] = value;
                    }
                    break;
                case 'u':
                    characters.resize(count);
                    for (quint32 i = 0; i < count && valid; ++i) {
                        quint8 value = 0;
                        valid = reader.byte(value);
                        characters[i] = char(value);
                    }
                    break;
                case 'l':
                    characters.resize(count);
                    for (quint32 i = 0; i < count && valid; ++i) valid = reader.logical(characters[i]);
                    break;
                case 'c':
                    characters.resize(count);
                    for (quint32 i = 0; i < count && valid; ++i) valid = reader.character(characters[i]);
                    break;
                default:
                    valid = false;
                }
                if (!valid) break;
                if (type == 29 && field.name == "pvec" && field.type == 'v' && count == 1) {
                    for (int axis = 0; axis < 3; ++axis) {
                        position[axis] = reals64[axis];
                        if (!std::isfinite(position[axis])) valid = false;
                    }
                    hasPosition = valid;
                }
                // An edge's tolerance; unset is Parasolid's null double (−3.14158e13) or '?'.
                if ((type == 16 || type == 18) && field.name == "tolerance" && field.type == 'f' && count == 1 &&
                    std::isfinite(reals64[0]) && reals64[0] > 0.0)
                    edgeTolerance = reals64[0];
                if (analyticGeometry(type) && field.type == 'v' && count == 1) {
                    std::array<double, 3> vector{reals64[0], reals64[1], reals64[2]};
                    for (double component : vector)
                        if (!std::isfinite(component)) valid = false;
                    vectors.insert(field.name, vector);
                }
                if (analyticGeometry(type) && field.type == 'f' && count == 1) {
                    if (!std::isfinite(reals64[0])) valid = false;
                    reals.insert(field.name, reals64[0]);
                }
                if (analyticGeometry(type) && field.type == 'f' &&
                    (count > 1 || type == 45 || type == 128)) {
                    for (double value : reals64)
                        if (!std::isfinite(value)) valid = false;
                    realArrays.insert(field.name, reals64);
                }
                if (analyticGeometry(type) && (field.type == 'n' || field.type == 'd') &&
                    count == 1) {
                    integers.insert(field.name, numbers[0]);
                }
                if (type == 127 && field.type == 'n') integerArrays.insert(field.name, numbers);
                // The points of an intersection curve's chart and limits (only an hvec's pvec is
                // transmitted): what locates the branch, and a blend's spine, along the curve.
                if ((type == 40 || type == 41) && field.type == 'h') {
                    for (double value : reals64)
                        if (!std::isfinite(value)) valid = false;
                    realArrays.insert(field.name, reals64);
                }
                if (analyticGeometry(type) &&
                    (field.type == 'u' || field.type == 'l' || field.type == 'c') &&
                    count == 1)
                    bytes.insert(field.name, characters[0]);
                if ((type == 14 || type == 17 || analyticGeometry(type)) &&
                    field.name == "sense" && field.type == 'c' && count == 1)
                    sense = characters[0];
                if ((type == 79 || type == 84) && field.type == 'c')
                    text = QByteArray(characters.data(), qsizetype(characters.size()));
                if (type == 83 && field.type == 'f') values = reals64;
                if (type == 100) {
                    if (field.name == "rotation_matrix" && field.type == 'f' && count == 9)
                        std::copy(reals64.begin(), reals64.end(), transform.rotation.begin());
                    else if (field.name == "translation_vector" && field.type == 'v' && count == 1)
                        std::copy(reals64.begin(), reals64.end(), transform.translation.begin());
                    else if (field.name == "scale" && field.type == 'f' && count == 1)
                        transform.scale = reals64[0];
                    else if (field.name == "flag" && field.type == 'd' && count == 1)
                        transform.flag = numbers[0];
                }
                if (((type == 12 && field.name == "body_type") || (type == 11 && field.name == "type")) &&
                    field.type == 'u' && count == 1)
                    kind = quint8(characters[0]);
                if (type == 19 && field.name == "type" && field.type == 'c' && count == 1)
                    kind = quint8(characters[0]);
            }
            if (!valid) break;
        }
        if (!valid) break;
        types.insert(nodeIndex, type);
        ++topology.nodeCount;
        if (type == 12) {
            ++topology.bodyCount;
            topology.bodies.push_back({nodeIndex, kind});
        } else if (type == 13) {
            ++topology.shellCount;
            topology.shellBodies.insert(nodeIndex, links.value("body"));
            topology.shellRegions.insert(nodeIndex, links.value("region"));
        } else if (type == 10) {
            topology.assemblies.push_back({nodeIndex, links.value("sub_instance")});
        } else if (type == 11) {
            topology.instances.push_back({nodeIndex, links.value("part"), links.value("transform"),
                                          links.value("assembly"), links.value("next_in_part"), kind});
        } else if (type == 100) {
            transform.index = nodeIndex;
            topology.transforms.push_back(transform);
        } else if (type == 79 || type == 84) {
            strings.insert(nodeIndex, text);
        } else if (type == 83) {
            realValues.insert(nodeIndex, std::move(values));
        } else if (type == 80) {
            definitionNames.insert(nodeIndex, links.value("identifier"));
        } else if (type == 81) {
            rawAttributes.push_back({nodeIndex, links.value("definition"), links.value("owner"),
                                     linkArrays.value("fields")});
        }
        else if (type == 19) {
            ++topology.regionCount;
            topology.regionTypes.insert(nodeIndex, kind);
            topology.regionBodies.insert(nodeIndex, links.value("body"));
        }
        else if (type == 29) {
            if (!hasPosition) break;
            points.insert(nodeIndex, position);
            if (topology.pointCount == 0) {
                topology.pointMin = position;
                topology.pointMax = position;
            } else {
                for (int axis = 0; axis < 3; ++axis) {
                    topology.pointMin[axis] = std::min(topology.pointMin[axis], position[axis]);
                    topology.pointMax[axis] = std::max(topology.pointMax[axis], position[axis]);
                }
            }
            ++topology.pointCount;
        } else if (type == 18) {
            topology.vertices.push_back({nodeIndex, links.value("point"), {}, edgeTolerance});
        } else if (type == 16) {
            topology.edges.push_back({nodeIndex, links.value("fin"), links.value("curve"), edgeTolerance});
        } else if (type == 14) {
            const quint32 shell = links.value("shell") ? links.value("shell") : links.value("front_shell");
            topology.faces.push_back({nodeIndex, shell, links.value("loop"),
                                      links.value("surface"), sense,
                                      links.value("shell"), links.value("front_shell")});
        } else if (type == 15) {
            topology.loops.push_back({nodeIndex, links.value("fin"),
                                      links.value("face"), links.value("next")});
        } else if (type == 17) {
            topology.fins.push_back({nodeIndex, links.value("loop"),
                                     links.value("forward"), links.value("backward"),
                                     links.value("vertex"), links.value("other"),
                                     links.value("edge"), links.value("curve"), sense});
        } else if (analyticGeometry(type)) {
            topology.analyticGeometry.push_back({nodeIndex, type, sense,
                                                  std::move(links), std::move(linkArrays),
                                                  std::move(vectors),
                                                  std::move(reals),
                                                  std::move(integers),
                                                  std::move(bytes),
                                                  std::move(realArrays),
                                                  std::move(integerArrays)});
        }
    }
    if (!terminated) {
        // Where the stream stopped making sense: enough to tell a damaged file from a node or an
        // encoding case the reader does not know.
        const quint32 decoded = topology.nodeCount;
        topology = {};
        error = QObject::tr("Не удалось полностью прочитать граф узлов Parasolid XT: разобрано узлов %1, "
                            "остановка на узле типа %2 (смещение %3 в потоке данных).")
                    .arg(decoded).arg(lastType).arg(lastStart);
        return false;
    }
    if (topology.bodyCount == 0 || topology.faces.empty()) {
        topology = {};
        error = QObject::tr("Не удалось полностью прочитать граф узлов Parasolid XT.");
        return false;
    }
    for (ParasolidXtVertex& vertex : topology.vertices) {
        const auto found = points.constFind(vertex.pointIndex);
        if (found == points.cend() || !refersTo(types, vertex.pointIndex, 29)) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT вершина ссылается на отсутствующую точку.");
            return false;
        }
        vertex.position = found.value();
    }
    for (const ParasolidXtEdge& edge : topology.edges) {
        if (!refersTo(types, edge.finIndex, 17) ||
            (edge.curveIndex != 0 && !types.contains(edge.curveIndex))) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT повреждены связи ребра.");
            return false;
        }
    }
    for (const ParasolidXtFace& face : topology.faces) {
        if (!refersTo(types, face.shellIndex, 13) ||
            !refersTo(types, face.loopIndex, 15) ||
            (face.surfaceIndex != 0 && !types.contains(face.surfaceIndex))) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT повреждены связи грани.");
            return false;
        }
    }
    for (const ParasolidXtLoop& loop : topology.loops) {
        if (!refersTo(types, loop.finIndex, 17) ||
            !refersTo(types, loop.faceIndex, 14) ||
            !refersTo(types, loop.nextIndex, 15)) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT повреждены связи контура.");
            return false;
        }
    }
    for (const ParasolidXtFin& fin : topology.fins) {
        if (!refersTo(types, fin.loopIndex, 15) ||
            !refersTo(types, fin.forwardIndex, 17) ||
            !refersTo(types, fin.backwardIndex, 17) ||
            !refersTo(types, fin.vertexIndex, 18) ||
            !refersTo(types, fin.otherIndex, 17) ||
            !refersTo(types, fin.edgeIndex, 16) ||
            (fin.curveIndex != 0 && !types.contains(fin.curveIndex))) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT повреждены связи ориентированного ребра.");
            return false;
        }
    }
    for (const ParasolidXtAnalyticGeometry& geometry : topology.analyticGeometry) {
        if (geometry.type != 38) continue;
        const auto supports = geometry.linkArrays.value("surface");
        if (supports.size() != 2 || supports[0] == 0 || supports[1] == 0 ||
            !types.contains(supports[0]) || !types.contains(supports[1])) {
            topology = {};
            error = QObject::tr("В кривой пересечения Parasolid XT повреждены ссылки на поверхности.");
            return false;
        }
    }
    // Shells belong to bodies, instances to assemblies and name a body or an assembly: a broken
    // link here would put a face into the wrong part or a part into the wrong place.
    for (auto it = topology.shellBodies.cbegin(); it != topology.shellBodies.cend(); ++it) {
        const quint32 region = topology.shellRegions.value(it.key());
        if ((it.value() != 0 && !refersTo(types, it.value(), 12)) ||
            (region != 0 && !refersTo(types, region, 19)) ||
            (it.value() == 0 && region == 0)) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT оболочка не принадлежит ни телу, ни области.");
            return false;
        }
    }
    for (auto it = topology.regionBodies.cbegin(); it != topology.regionBodies.cend(); ++it) {
        if (!refersTo(types, it.value(), 12)) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT область не ссылается на тело.");
            return false;
        }
    }
    for (const ParasolidXtInstance& instance : topology.instances) {
        const bool partOk = refersTo(types, instance.partIndex, 12) || refersTo(types, instance.partIndex, 10);
        if (!partOk || !refersTo(types, instance.assemblyIndex, 10) ||
            (instance.transformIndex != 0 && !refersTo(types, instance.transformIndex, 100)) ||
            (instance.nextInAssembly != 0 && !refersTo(types, instance.nextInAssembly, 11))) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT повреждены связи экземпляра сборки.");
            return false;
        }
    }
    for (const ParasolidXtAssembly& assembly : topology.assemblies) {
        if (assembly.firstInstance != 0 && !refersTo(types, assembly.firstInstance, 11)) {
            topology = {};
            error = QObject::tr("В графе Parasolid XT повреждены связи сборки.");
            return false;
        }
    }
    for (const RawAttribute& raw : rawAttributes) {
        const auto name = definitionNames.constFind(raw.definition);
        if (name == definitionNames.cend() || !strings.contains(name.value())) continue;
        ParasolidXtAttribute attribute;
        attribute.index = raw.index;
        attribute.ownerIndex = raw.owner;
        attribute.definition = strings.value(name.value());
        for (quint32 field : raw.fields) {
            if (strings.contains(field)) attribute.strings.push_back(strings.value(field));
            else if (realValues.contains(field)) {
                const auto& reals = realValues[field];
                attribute.reals.insert(attribute.reals.end(), reals.begin(), reals.end());
            }
        }
        topology.attributes.push_back(std::move(attribute));
    }
    topology.nodeTypes = std::move(types);
    error.clear();
    return true;
}

} // namespace

bool readParasolidXtTopology(const QByteArray& partition,
                            ParasolidXtTopology& topology, QString& error) {
    topology = {};
    XtReader reader(partition, false);
    XtHeader header;
    if (!readXtHeader(reader, header, error)) return false;
    // A SOLIDWORKS part stores a partition whose root is the WORLD node.
    quint16 root = 0;
    const qsizetype at = reader.position();
    if (!header.partition || !reader.i16(root) || root != 101) {
        error = QObject::tr("Неподдерживаемый заголовок или схема раздела Parasolid XT.");
        return false;
    }
    reader.seek(at);
    return decodeXtNodes(reader, header.maxType, topology, error);
}

bool readParasolidXtFile(const QByteArray& file, ParasolidXtTopology& topology, QString& error) {
    topology = {};
    // Both encodings open with the same printable keyword header (**PART1 … **END_OF_HEADER); the
    // data begin on the line after it.
    const qsizetype marker = file.indexOf("**END_OF_HEADER");
    const qsizetype lineEnd = marker < 0 ? -1 : file.indexOf('\n', marker);
    if (lineEnd < 0) {
        error = QObject::tr("Это не файл Parasolid XT: нет заголовка **END_OF_HEADER.");
        return false;
    }
    QByteArray payload = file.mid(lineEnd + 1);
    const bool text = payload.startsWith('T');
    if (text) {
        // Parasolid splits its text stream into records of about 80 characters. On reading, the
        // line breaks and any trailing spaces added to a record are ignored (XT Format Reference,
        // "Text"); leading spaces are data.
        QByteArray joined;
        joined.reserve(payload.size());
        for (QByteArray record : payload.split('\n')) {
            record.replace('\r', QByteArray());
            qsizetype end = record.size();
            while (end > 0 && record[end - 1] == ' ') --end;
            joined.append(record.constData(), end);
        }
        payload = std::move(joined);
    } else if (!payload.startsWith(QByteArray("PS\0\0", 4))) {
        error = QObject::tr("Двоичный Parasolid XT в формате, отличном от нейтрального (bare binary зависит от машины-писателя), не поддержан.");
        return false;
    }
    XtReader reader(payload, text);
    XtHeader header;
    if (!readXtHeader(reader, header, error)) return false;
    return decodeXtNodes(reader, header.maxType, topology, error);
}

std::vector<ParasolidXtFieldSpec> parasolidXtBaseSchema(quint16 type) {
    std::vector<XtField> fields;
    std::vector<ParasolidXtFieldSpec> specs;
    if (!parseBaseFields(baseFields(type), fields)) return specs;
    for (const XtField& field : fields) specs.push_back({field.name, field.type, field.count, field.variable});
    return specs;
}

ParasolidXtTopology parasolidXtBodyTopology(const ParasolidXtTopology& topology,
                                            quint32 bodyIndex) {
    ParasolidXtTopology body;
    QSet<quint32> faces, loops, edges, vertices;
    // A shell's body is its own field when set, otherwise that of its region.
    const auto ownerOf = [&](quint32 shell) {
        const quint32 direct = topology.shellBodies.value(shell);
        return direct != 0 ? direct : topology.regionBodies.value(topology.shellRegions.value(shell));
    };
    for (auto it = topology.shellBodies.cbegin(); it != topology.shellBodies.cend(); ++it) {
        if (ownerOf(it.key()) != bodyIndex) continue;
        body.shellBodies.insert(it.key(), it.value());
        const quint32 region = topology.shellRegions.value(it.key());
        body.shellRegions.insert(it.key(), region);
        body.regionBodies.insert(region, bodyIndex);
        if (topology.regionTypes.contains(region)) body.regionTypes.insert(region, topology.regionTypes.value(region));
        ++body.shellCount;
    }
    body.regionCount = quint32(body.regionTypes.size());
    for (const ParasolidXtFace& face : topology.faces) {
        // A face lies between two shells of one body; either side names it.
        if (ownerOf(face.backShellIndex) != bodyIndex && ownerOf(face.frontShellIndex) != bodyIndex) continue;
        body.faces.push_back(face);
        faces.insert(face.index);
    }
    for (const ParasolidXtLoop& loop : topology.loops) {
        if (!faces.contains(loop.faceIndex)) continue;
        body.loops.push_back(loop);
        loops.insert(loop.index);
    }
    for (const ParasolidXtFin& fin : topology.fins) {
        if (!loops.contains(fin.loopIndex)) continue;
        body.fins.push_back(fin);
        edges.insert(fin.edgeIndex);
        vertices.insert(fin.vertexIndex);
    }
    for (const ParasolidXtEdge& edge : topology.edges)
        if (edges.contains(edge.index)) body.edges.push_back(edge);
    for (const ParasolidXtVertex& vertex : topology.vertices) {
        if (!vertices.contains(vertex.index)) continue;
        if (body.pointCount == 0) {
            body.pointMin = vertex.position;
            body.pointMax = vertex.position;
        }
        for (int axis = 0; axis < 3; ++axis) {
            body.pointMin[axis] = std::min(body.pointMin[axis], vertex.position[axis]);
            body.pointMax[axis] = std::max(body.pointMax[axis], vertex.position[axis]);
        }
        ++body.pointCount;
        body.vertices.push_back(vertex);
    }
    for (const ParasolidXtBody& candidate : topology.bodies)
        if (candidate.index == bodyIndex) body.bodies.push_back(candidate);
    body.bodyCount = quint32(body.bodies.size());
    body.analyticGeometry = topology.analyticGeometry;
    body.nodeTypes = topology.nodeTypes;
    body.nodeCount = topology.nodeCount;
    return body;
}

std::vector<ParasolidXtPlanarFace> parasolidXtPlanarFaces(
    const ParasolidXtTopology& topology) {
    QHash<quint32, const ParasolidXtVertex*> vertices;
    QHash<quint32, const ParasolidXtEdge*> edges;
    QHash<quint32, const ParasolidXtLoop*> loops;
    QHash<quint32, const ParasolidXtFin*> fins;
    QHash<quint32, const ParasolidXtAnalyticGeometry*> geometry;
    for (const auto& vertex : topology.vertices) vertices.insert(vertex.index, &vertex);
    for (const auto& edge : topology.edges) edges.insert(edge.index, &edge);
    for (const auto& loop : topology.loops) loops.insert(loop.index, &loop);
    for (const auto& fin : topology.fins) fins.insert(fin.index, &fin);
    for (const auto& item : topology.analyticGeometry) geometry.insert(item.index, &item);

    std::vector<ParasolidXtPlanarFace> result;
    for (const ParasolidXtFace& face : topology.faces) {
        const auto* plane = geometry.value(face.surfaceIndex, nullptr);
        const auto* loop = loops.value(face.loopIndex, nullptr);
        if (!plane || plane->type != 50 || !loop || loop->nextIndex != 0 ||
            loop->faceIndex != face.index || loop->finIndex == 0 ||
            !plane->vectors.contains("pvec") || !plane->vectors.contains("normal") ||
            (plane->sense != '+' && plane->sense != '-') ||
            (face.sense != '+' && face.sense != '-')) continue;
        ParasolidXtPlanarFace candidate;
        candidate.faceIndex = face.index;
        candidate.planeOrigin = plane->vectors.value("pvec");
        candidate.planeNormal = plane->vectors.value("normal");
        if ((plane->sense == '-') != (face.sense == '-')) {
            for (double& value : candidate.planeNormal) value = -value;
        }
        const quint32 firstFin = loop->finIndex;
        quint32 finIndex = firstFin;
        QSet<quint32> visited;
        std::vector<const ParasolidXtAnalyticGeometry*> edgeLines;
        bool valid = true;
        while (finIndex != 0 && !visited.contains(finIndex) &&
               visited.size() <= qsizetype(topology.fins.size())) {
            visited.insert(finIndex);
            const auto* fin = fins.value(finIndex, nullptr);
            const auto* vertex = fin ? vertices.value(fin->vertexIndex, nullptr) : nullptr;
            const auto* edge = fin ? edges.value(fin->edgeIndex, nullptr) : nullptr;
            const auto* curve = edge ? geometry.value(edge->curveIndex, nullptr) : nullptr;
            const auto* next = fin ? fins.value(fin->forwardIndex, nullptr) : nullptr;
            const auto* other = fin ? fins.value(fin->otherIndex, nullptr) : nullptr;
            const auto* anchor = edge ? fins.value(edge->finIndex, nullptr) : nullptr;
            if (!fin || fin->loopIndex != loop->index || !vertex ||
                !edge || !curve || curve->type != 30 ||
                !curve->vectors.contains("pvec") ||
                !curve->vectors.contains("direction") ||
                !next || next->backwardIndex != fin->index ||
                !anchor || anchor->edgeIndex != edge->index ||
                !other || other->edgeIndex != edge->index) {
                valid = false;
                break;
            }
            candidate.outline.push_back(vertex->position);
            edgeLines.push_back(curve);
            finIndex = fin->forwardIndex;
        }
        if (!valid || finIndex != firstFin || candidate.outline.size() < 3) continue;
        const auto& origin = candidate.planeOrigin;
        const auto& normal = candidate.planeNormal;
        const double norm = std::hypot(normal[0], normal[1], normal[2]);
        if (!std::isfinite(norm) || norm < 1e-12) continue;
        std::array<double, 3> areaNormal{};
        double extent = 0.0;
        for (std::size_t i = 0; i < candidate.outline.size(); ++i) {
            const auto& a = candidate.outline[i];
            const auto& b = candidate.outline[(i + 1) % candidate.outline.size()];
            const std::array<double, 3> va{a[0] - origin[0], a[1] - origin[1], a[2] - origin[2]};
            const std::array<double, 3> vb{b[0] - origin[0], b[1] - origin[1], b[2] - origin[2]};
            extent = std::max(extent, std::hypot(va[0], va[1], va[2]));
            const double distance = (va[0] * normal[0] + va[1] * normal[1] +
                                     va[2] * normal[2]) / norm;
            if (!std::isfinite(distance) || std::fabs(distance) > 1e-8) {
                valid = false;
                break;
            }
            if (std::hypot(b[0] - a[0], b[1] - a[1], b[2] - a[2]) <= 1e-12) {
                valid = false;
                break;
            }
            // FIN.vertex is the forward endpoint. The curve of fin i must
            // contain both the preceding and current forward vertices.
            const auto* line = edgeLines[i];
            const auto& lineOrigin = line->vectors.value("pvec");
            const auto& direction = line->vectors.value("direction");
            const double directionLength = std::hypot(direction[0], direction[1], direction[2]);
            if (directionLength < 1e-12 || !std::isfinite(directionLength)) {
                valid = false;
                break;
            }
            const auto onLine = [&](const std::array<double, 3>& point) {
                const double dx = point[0] - lineOrigin[0];
                const double dy = point[1] - lineOrigin[1];
                const double dz = point[2] - lineOrigin[2];
                const double cx = dy * direction[2] - dz * direction[1];
                const double cy = dz * direction[0] - dx * direction[2];
                const double cz = dx * direction[1] - dy * direction[0];
                return std::hypot(cx, cy, cz) / directionLength <= 1e-8;
            };
            if (!onLine(candidate.outline[(i + candidate.outline.size() - 1) %
                                           candidate.outline.size()]) ||
                !onLine(a)) {
                valid = false;
                break;
            }
            areaNormal[0] += va[1] * vb[2] - va[2] * vb[1];
            areaNormal[1] += va[2] * vb[0] - va[0] * vb[2];
            areaNormal[2] += va[0] * vb[1] - va[1] * vb[0];
        }
        if (!valid) continue;
        const double twiceArea = (areaNormal[0] * normal[0] +
                                  areaNormal[1] * normal[1] +
                                  areaNormal[2] * normal[2]) / norm;
        if (!std::isfinite(twiceArea) ||
            std::fabs(twiceArea) <= std::max(1e-16, extent * extent * 1e-12)) continue;
        if (twiceArea < 0.0) std::reverse(candidate.outline.begin(), candidate.outline.end());
        result.push_back(std::move(candidate));
    }
    return result;
}

bool parasolidXtFaceWires(const ParasolidXtTopology& topology,
                         std::vector<ParasolidXtFaceWire>& wires,
                         QString& error) {
    wires.clear();
    QHash<quint32, const ParasolidXtVertex*> vertices;
    QHash<quint32, const ParasolidXtEdge*> edges;
    QHash<quint32, const ParasolidXtLoop*> loops;
    QHash<quint32, const ParasolidXtFin*> fins;
    for (const auto& item : topology.vertices) vertices.insert(item.index, &item);
    for (const auto& item : topology.edges) edges.insert(item.index, &item);
    for (const auto& item : topology.loops) loops.insert(item.index, &item);
    for (const auto& item : topology.fins) fins.insert(item.index, &item);
    QSet<quint32> usedLoops;
    QSet<quint32> usedFins;
    const auto fail = [&](quint32 faceIndex, const char* reason) {
        wires.clear();
        error = QObject::tr("Нарушен контур грани Parasolid XT %1: %2")
                    .arg(faceIndex).arg(QLatin1String(reason));
        return false;
    };
    for (const auto& face : topology.faces) {
        quint32 loopIndex = face.loopIndex;
        if (loopIndex == 0) return fail(face.index, "нет первого контура");
        while (loopIndex != 0) {
            const auto* loop = loops.value(loopIndex, nullptr);
            if (!loop || loop->faceIndex != face.index ||
                usedLoops.contains(loopIndex) || loop->finIndex == 0)
                return fail(face.index, "неверная ссылка на контур");
            usedLoops.insert(loopIndex);
            ParasolidXtFaceWire wire;
            wire.faceIndex = face.index;
            wire.loopIndex = loopIndex;
            quint32 finIndex = loop->finIndex;
            QSet<quint32> localFins;
            do {
                const auto* fin = fins.value(finIndex, nullptr);
                if (!fin || fin->loopIndex != loopIndex ||
                    localFins.contains(finIndex) || usedFins.contains(finIndex))
                    return fail(face.index, "неверная ссылка на ориентированное ребро");
                const auto* previous = fins.value(fin->backwardIndex, nullptr);
                const auto* next = fins.value(fin->forwardIndex, nullptr);
                const auto* edge = edges.value(fin->edgeIndex, nullptr);
                const auto* start = previous
                    ? vertices.value(previous->vertexIndex, nullptr) : nullptr;
                const auto* end = vertices.value(fin->vertexIndex, nullptr);
                if (!previous || !next ||
                    previous->forwardIndex != finIndex ||
                    next->backwardIndex != finIndex ||
                    previous->loopIndex != loopIndex ||
                    next->loopIndex != loopIndex)
                    return fail(face.index, "ориентация рёбер не замыкается");
                const bool pointLoop = !edge && fin->edgeIndex == 0 &&
                    fin->forwardIndex == finIndex && start && end &&
                    previous->vertexIndex == fin->vertexIndex;
                if (!edge && !pointLoop)
                    return fail(face.index, "у ориентированного ребра нет EDGE");
                // A tolerant edge may have no curve: each fin then carries its own.
                const bool finCurve = edge && edge->curveIndex == 0 && fin->curveIndex != 0;
                const quint32 curveIndex = edge ? (finCurve ? fin->curveIndex : edge->curveIndex) : 0;
                const quint16 curveType = topology.nodeTypes.value(curveIndex);
                const bool closedCurveWithoutVertex =
                    fin->forwardIndex == finIndex && !start && !end &&
                    curveType != 0;
                if ((!start || !end) && !closedCurveWithoutVertex)
                    return fail(face.index, "у ребра отсутствует вершина");
                wire.segments.push_back({finIndex, edge ? edge->index : 0,
                                          curveIndex,
                                          curveType,
                                          fin->sense,
                                          !closedCurveWithoutVertex,
                                          start ? start->position : std::array<double, 3>{},
                                          end ? end->position : std::array<double, 3>{},
                                          finCurve,
                                          [&] {
                                              // The edge's tolerance and its vertices': how far its
                                              // curves may be from its faces and from each other.
                                              double t = std::numeric_limits<double>::quiet_NaN();
                                              for (const double v : {edge ? edge->tolerance : t,
                                                                     start ? start->tolerance : t,
                                                                     end ? end->tolerance : t})
                                                  if (std::isfinite(v)) t = std::isfinite(t) ? std::max(t, v) : v;
                                              return t;
                                          }()});
                localFins.insert(finIndex);
                usedFins.insert(finIndex);
                finIndex = fin->forwardIndex;
            } while (finIndex != loop->finIndex && finIndex != 0 &&
                     localFins.size() <= qsizetype(topology.fins.size()));
            if (finIndex != loop->finIndex || wire.segments.empty())
                return fail(face.index, "контур не замкнут");
            wires.push_back(std::move(wire));
            loopIndex = loop->nextIndex;
        }
    }
    if (usedLoops.size() != qsizetype(topology.loops.size()) ||
        usedFins.size() != qsizetype(topology.fins.size())) {
        wires.clear();
        error = QObject::tr("Граф Parasolid XT содержит контуры или рёбра вне граней.");
        return false;
    }
    error.clear();
    return true;
}

} // namespace cadnext::gui
