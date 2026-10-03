#pragma once

#include "cadnext/gui/NativeKompasOperation.hpp"

#include <QByteArray>
#include <QString>

#include <array>
#include <cstddef>
#include <vector>

namespace cadnext::gui {

// The seven default datums of a KOMPAS 17.1 document as KOMPAS writes them — the
// same in all 21 v17 parts and 5 v17 assemblies of the samples but for their ids
// and main names: Плоскость XY, ZX, ZY, Ось X, Y, Z, Начало координат; variables
// v1..v7; their colours; native names 1, 1, 2, 3, 4, 5, 6. `nativeType` is 9 in a
// part, 25 in an assembly. Ids and main names run on from the first ones given.
std::vector<KompasDatum> kompasDefaultDatums(quint8 nativeType, quint16 firstObjectId, quint32 firstMainName);

// A component of an assembly (/#170/#110/<index>), read from the 20 components
// of the 5 v17 assemblies of the samples: its index, its box in the assembly
// (written three times), its frame (origin, then the X, Y and Z axes, mm), the
// file link it places, then the component's own data — six counters, two
// variables (v(6 + 2·index), v(7 + 2·index): "Исключить из расчета",
// "Фиксировать компонент") and two optional names — around runs of data the
// same in every sample. The counters follow from the number of bodies of the
// placed part (B) and which placement of that part this is (I, from 1):
// 14 + 3B + 2(I − 1), 7 + B, B, 2 + I, 0, 4 + B + (I − 1).
struct KompasComponentRecord {
    quint32 version = 3; // 3 or 4 in the samples, their roles not known
    quint32 index = 1;
    std::array<double, 6> box{};
    std::array<double, 12> frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    quint16 link = 0;
    quint32 bodies = 1;
    quint32 instance = 1;
    QString instanceName; // written by KOMPAS for a second placement of a part
    QString display;      // "designation name", in some samples
};

// Outputs are reset on failure; a record outside this layout is refused.
bool encodeKompasComponentRecord(const KompasComponentRecord& record, QByteArray& bytes, QString& error);
bool decodeKompasComponentRecord(const QByteArray& bytes, KompasComponentRecord& record, QString& error);

// /MetoInfoLinks of an assembly: one entry per component, keyed as KOMPAS keys
// them. A key follows the order in which the document's components were made: an
// assembly with nothing deleted holds the first n keys of one sequence (v17: 1 to 5,
// order too; v24: the sets 1–16, 1–20, 1–21). Its rule is not known, so the keys
// are a table, 1 to 21, and more components are refused (NativeKompasAssembly.cpp).
constexpr std::size_t kKompasAssemblyLinkKeys = 21;
bool encodeKompasAssemblyMetaInfoLinks(std::size_t components, QByteArray& bytes, QString& error);
bool decodeKompasAssemblyMetaInfoLinks(const QByteArray& bytes, std::size_t& components, QString& error);

// /#170/#110 of an assembly: the catalog's last object id and an empty list.
bool encodeKompasAssemblyModelCounter(quint32 lastObjectId, QByteArray& bytes, QString& error);
bool decodeKompasAssemblyModelCounter(const QByteArray& bytes, quint32& lastObjectId, QString& error);

// /#114: 0 and a count — 7 in most parts, 7 + 2·components in every assembly.
bool encodeKompasDocumentCounter(quint32 value, QByteArray& bytes, QString& error);
bool decodeKompasDocumentCounter(const QByteArray& bytes, quint32& value, QString& error);

} // namespace cadnext::gui
