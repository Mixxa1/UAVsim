#include "cadnext/gui/NativeCompoundFile.hpp"

#include <QMap>
#include <QObject>
#include <QStringList>

#include <algorithm>
#include <functional>
#include <limits>
#include <stdexcept>
#include <utility>

namespace cadnext::gui {
namespace {

// MS-CFB, sections 2.2 through 2.6.4:
// https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b
constexpr quint32 kFree = 0xffffffffu;
constexpr quint32 kEnd = 0xfffffffeu;
constexpr quint32 kFat = 0xfffffffdu;
constexpr quint32 kDifat = 0xfffffffcu;
constexpr quint64 kMaxBytes = 512ull * 1024 * 1024;
constexpr quint64 kMaxStreamBytes = 256ull * 1024 * 1024;
constexpr std::size_t kMaxEntries = 65536;
constexpr int kMaxDepth = 64;

quint64 number(const QByteArray& bytes, qsizetype at, int width) {
    if (at < 0 || at > bytes.size() || width > bytes.size() - at)
        throw std::runtime_error("Truncated compound-file field");
    quint64 value = 0;
    for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at + i])) << (8 * i);
    return value;
}

void put(QByteArray& bytes, qsizetype at, quint64 value, int width) {
    for (int i = 0; i < width; ++i) bytes[at + i] = char((value >> (8 * i)) & 0xff);
}

quint32 blocks(quint64 bytes, quint32 size) { return quint32((bytes + size - 1) / size); }

void validateName(const QString& name) {
    if (name.isEmpty() || name.size() > 31 || name == "." || name == "..")
        throw std::runtime_error("Invalid compound-file name length");
    for (const auto c : name)
        if (c.isNull() || c == '/' || c == '\\' || c == ':' || c == '!')
            throw std::runtime_error("Invalid compound-file name character");
}

int compareNames(const QString& a, const QString& b) {
    if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
    for (qsizetype i = 0; i < a.size(); ++i) {
        // Simple uppercase mapping of one UTF-16 unit. Surrogates remain
        // unchanged; full-string folding would change the CFB sort order.
        const auto x = a[i].toUpper().unicode(), y = b[i].toUpper().unicode();
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

struct Node {
    CompoundFileEntry entry;
    QString name;
    quint8 type = 0, color = 1;
    quint32 left = kFree, right = kFree, child = kFree, start = kEnd;
    quint64 size = 0;
};

QString failure(const std::exception& e) {
    return QObject::tr("Контейнер CFB: %1").arg(QString::fromUtf8(e.what()));
}

class Decoder {
public:
    explicit Decoder(const QByteArray& bytes) : bytes_(bytes) {}

    CompoundFile decode() {
        if (quint64(bytes_.size()) > kMaxBytes || bytes_.size() < 512 ||
            bytes_.left(8) != QByteArray::fromHex("d0cf11e0a1b11ae1"))
            throw std::runtime_error("Invalid compound-file signature or size");
        version_ = quint16(number(bytes_, 26, 2));
        const auto shift = number(bytes_, 30, 2);
        if ((version_ != 3 && version_ != 4) || shift != (version_ == 3 ? 9 : 12) ||
            number(bytes_, 28, 2) != 0xfffe || number(bytes_, 32, 2) != 6 ||
            number(bytes_, 56, 4) != 4096 || bytes_.mid(8, 16) != QByteArray(16, '\0') ||
            bytes_.mid(34, 6) != QByteArray(6, '\0'))
            throw std::runtime_error("Unsupported compound-file header");
        sectorSize_ = quint32(1u << shift);
        if (bytes_.size() % sectorSize_ || bytes_.size() < qsizetype(sectorSize_) ||
            (version_ == 4 && bytes_.mid(512, sectorSize_ - 512) != QByteArray(sectorSize_ - 512, '\0')))
            throw std::runtime_error("Invalid compound-file sector extent");
        sectorCount_ = quint32(bytes_.size() / sectorSize_ - 1);
        owned_.resize(sectorCount_);
        const auto fatCount = quint32(number(bytes_, 44, 4));
        const auto difatCount = quint32(number(bytes_, 72, 4));
        if (!fatCount || fatCount > sectorCount_ || difatCount > sectorCount_ ||
            (version_ == 3 && number(bytes_, 40, 4)))
            throw std::runtime_error("Invalid compound-file allocation counts");
        std::vector<quint32> fatSectors, difatSectors;
        const auto appendFat = [&](quint32 id) {
            if (fatSectors.size() >= fatCount) {
                if (id != kFree) throw std::runtime_error("Extra FAT sector location");
            } else {
                own(id); fatSectors.push_back(id);
            }
        };
        for (int i = 0; i < 109; ++i) appendFat(quint32(number(bytes_, 76 + 4 * i, 4)));
        quint32 next = quint32(number(bytes_, 68, 4));
        for (quint32 i = 0; i < difatCount; ++i) {
            own(next); difatSectors.push_back(next);
            const auto data = sector(next);
            for (quint32 at = 0; at < sectorSize_ - 4; at += 4) appendFat(quint32(number(data, at, 4)));
            next = quint32(number(data, sectorSize_ - 4, 4));
        }
        if (next != kEnd || fatSectors.size() != fatCount)
            throw std::runtime_error("Invalid DIFAT termination");
        fat_.reserve(sectorCount_);
        for (const auto id : fatSectors) {
            const auto data = sector(id);
            for (quint32 at = 0; at < sectorSize_; at += 4) {
                const auto value = quint32(number(data, at, 4));
                if (fat_.size() < sectorCount_) fat_.push_back(value);
                else if (value != kFree) throw std::runtime_error("FAT references a nonexistent sector");
            }
        }
        if (fat_.size() < sectorCount_) throw std::runtime_error("Incomplete FAT");
        for (const auto id : fatSectors)
            if (fat_[id] != kFat) throw std::runtime_error("Invalid FAT sector marker");
        for (const auto id : difatSectors)
            if (fat_[id] != kDifat) throw std::runtime_error("Invalid DIFAT sector marker");
        const auto directory = chain(quint32(number(bytes_, 48, 4)));
        if (directory.isEmpty() || directory.size() / 128 > qsizetype(kMaxEntries) ||
            (version_ == 4 && quint64(directory.size()) != number(bytes_, 40, 4) * sectorSize_))
            throw std::runtime_error("Invalid compound-file directory extent");
        for (qsizetype at = 0; at < directory.size(); at += 128) nodes_.push_back(readNode(directory, at));
        if (nodes_[0].type != 5 || nodes_[0].left != kFree || nodes_[0].right != kFree ||
            nodes_[0].entry.createdAt)
            throw std::runtime_error("Invalid compound-file root entry");
        const auto miniFatCount = quint32(number(bytes_, 64, 4));
        if (miniFatCount > sectorCount_) throw std::runtime_error("Oversized MiniFAT");
        const auto miniFat = chain(quint32(number(bytes_, 60, 4)), quint64(miniFatCount) * sectorSize_);
        for (qsizetype at = 0; at < miniFat.size(); at += 4) miniFat_.push_back(quint32(number(miniFat, at, 4)));
        if (nodes_[0].size > kMaxBytes || nodes_[0].size % 64)
            throw std::runtime_error("Invalid mini-stream extent");
        miniStream_ = chain(nodes_[0].start, nodes_[0].size);
        miniOwned_.resize(std::size_t(miniStream_.size() / 64));
        if (miniFat_.size() < miniOwned_.size()) throw std::runtime_error("Incomplete MiniFAT");
        CompoundFile output;
        output.rootClassId = nodes_[0].entry.classId;
        output.rootStateBits = nodes_[0].entry.stateBits;
        output.rootModifiedAt = nodes_[0].entry.modifiedAt;
        seen_.resize(nodes_.size()); seen_[0] = true;
        walk(nodes_[0].child, {}, 0, 0, false, nullptr, nullptr, output);
        for (std::size_t i = 1; i < nodes_.size(); ++i)
            if (nodes_[i].type && !seen_[i]) throw std::runtime_error("Unreachable compound-file directory entry");
        for (quint32 i = 0; i < sectorCount_; ++i)
            if (!owned_[i] && fat_[i] != kFree) throw std::runtime_error("Unowned compound-file sector");
        for (std::size_t i = 0; i < miniOwned_.size(); ++i)
            if (!miniOwned_[i] && miniFat_[i] != kFree) throw std::runtime_error("Unowned mini-stream sector");
        return output;
    }

private:
    void own(quint32 id) {
        if (id >= sectorCount_ || owned_[id]) throw std::runtime_error("Invalid or shared compound-file sector");
        owned_[id] = true;
    }
    QByteArray sector(quint32 id) const {
        if (id >= sectorCount_) throw std::runtime_error("Invalid compound-file sector location");
        return bytes_.mid((quint64(id) + 1) * sectorSize_, sectorSize_);
    }
    QByteArray chain(quint32 id, quint64 size = std::numeric_limits<quint64>::max()) {
        const bool measured = size != std::numeric_limits<quint64>::max();
        if (measured && size > kMaxBytes) throw std::runtime_error("Oversized compound-file chain");
        const auto count = measured ? blocks(size, sectorSize_) : sectorCount_;
        QByteArray data;
        for (quint32 i = 0; id != kEnd; ++i) {
            if (i >= count) throw std::runtime_error("Compound-file chain length mismatch");
            own(id); data += sector(id); id = fat_[id];
        }
        if (measured) {
            if (quint64(data.size()) != quint64(count) * sectorSize_)
                throw std::runtime_error("Short compound-file chain");
            data.resize(qsizetype(size));
        }
        return data;
    }
    QByteArray miniChain(quint32 id, quint64 size) {
        QByteArray data;
        const auto count = blocks(size, 64);
        for (quint32 i = 0; i < count; ++i) {
            if (id >= miniOwned_.size() || miniOwned_[id]) throw std::runtime_error("Invalid or shared mini-stream sector");
            miniOwned_[id] = true; data += miniStream_.mid(qsizetype(id) * 64, 64); id = miniFat_[id];
        }
        if (id != kEnd) throw std::runtime_error("Mini-stream chain length mismatch");
        data.resize(qsizetype(size)); return data;
    }
    Node readNode(const QByteArray& directory, qsizetype at) {
        Node node; node.type = quint8(number(directory, at + 66, 1));
        if (!node.type) return node; // Unallocated entries can contain old metadata.
        if (node.type != 1 && node.type != 2 && node.type != 5)
            throw std::runtime_error("Invalid compound-file object type");
        const auto length = number(directory, at + 64, 2);
        if (length < 4 || length > 64 || length % 2 || number(directory, at + length - 2, 2))
            throw std::runtime_error("Invalid compound-file directory name");
        for (quint64 i = 0; i + 2 < length; i += 2) node.name.append(QChar(ushort(number(directory, at + i, 2))));
        validateName(node.name);
        node.color = quint8(number(directory, at + 67, 1));
        if (node.color > 1) throw std::runtime_error("Invalid compound-file tree color");
        node.left = quint32(number(directory, at + 68, 4));
        node.right = quint32(number(directory, at + 72, 4));
        node.child = quint32(number(directory, at + 76, 4));
        for (int i = 0; i < 16; ++i) node.entry.classId[std::size_t(i)] = quint8(number(directory, at + 80 + i, 1));
        node.entry.stateBits = quint32(number(directory, at + 96, 4));
        node.entry.createdAt = number(directory, at + 100, 8);
        node.entry.modifiedAt = number(directory, at + 108, 8);
        node.start = quint32(number(directory, at + 116, 4));
        // MS-CFB requires ignoring an uninitialized high DWORD in v3 files.
        node.size = number(directory, at + 120, version_ == 3 ? 4 : 8);
        node.entry.kind = node.type == 2 ? CompoundFileEntry::Kind::Stream : CompoundFileEntry::Kind::Storage;
        if (node.type == 1 && (node.start || node.size)) throw std::runtime_error("Invalid storage extent");
        if (node.type == 2 && (node.child != kFree || node.entry.createdAt || node.entry.modifiedAt ||
            node.entry.classId != std::array<quint8,16>{}))
            throw std::runtime_error("Invalid stream directory metadata");
        return node;
    }
    void walk(quint32 id, const QString& parent, int storageDepth, int treeDepth, bool parentRed,
              const QString* lower, const QString* upper, CompoundFile& output) {
        if (id == kFree) return;
        if (id >= nodes_.size() || seen_[id] || storageDepth >= kMaxDepth || treeDepth >= kMaxDepth)
            throw std::runtime_error("Invalid compound-file directory tree");
        seen_[id] = true; auto& node = nodes_[id];
        if ((node.type != 1 && node.type != 2) || (parentRed && !node.color) ||
            (lower && compareNames(*lower, node.name) >= 0) ||
            (upper && compareNames(node.name, *upper) >= 0))
            throw std::runtime_error("Invalid compound-file sibling order");
        walk(node.left, parent, storageDepth, treeDepth + 1, !node.color, lower, &node.name, output);
        node.entry.path = parent.isEmpty() ? node.name : parent + '/' + node.name;
        if (node.type == 2) {
            total_ += node.size;
            if (node.size > kMaxStreamBytes || total_ > kMaxBytes) throw std::runtime_error("Oversized compound-file stream");
            node.entry.data = node.size < 4096 ? miniChain(node.start, node.size) : chain(node.start, node.size);
        }
        output.entries.push_back(node.entry);
        if (node.type == 1) walk(node.child, node.entry.path, storageDepth + 1, 0, false, nullptr, nullptr, output);
        walk(node.right, parent, storageDepth, treeDepth + 1, !node.color, &node.name, upper, output);
    }
    const QByteArray& bytes_;
    quint16 version_ = 0;
    quint32 sectorSize_ = 0, sectorCount_ = 0;
    quint64 total_ = 0;
    std::vector<quint32> fat_, miniFat_;
    std::vector<bool> owned_, miniOwned_, seen_;
    std::vector<Node> nodes_;
    QByteArray miniStream_;
};

QByteArray encode(const CompoundFile& file) {
    if (file.entries.size() >= kMaxEntries) throw std::runtime_error("Too many compound-file entries");
    std::vector<Node> nodes(1);
    nodes[0].name = "Root Entry"; nodes[0].type = 5;
    nodes[0].entry.classId = file.rootClassId; nodes[0].entry.stateBits = file.rootStateBits;
    nodes[0].entry.modifiedAt = file.rootModifiedAt;
    QMap<QString,quint32> paths; paths.insert({},0);
    quint64 total = 0;
    for (const auto& entry : file.entries) {
        const auto names = entry.path.split('/');
        if (names.size() > kMaxDepth) throw std::runtime_error("Compound-file storage hierarchy too deep");
        for (const auto& name : names) validateName(name);
        if (paths.contains(entry.path)) throw std::runtime_error("Duplicate compound-file path");
        if (entry.kind != CompoundFileEntry::Kind::Storage && entry.kind != CompoundFileEntry::Kind::Stream)
            throw std::runtime_error("Invalid compound-file object kind");
        if (entry.kind == CompoundFileEntry::Kind::Storage && !entry.data.isEmpty())
            throw std::runtime_error("Storage object contains stream data");
        if (entry.kind == CompoundFileEntry::Kind::Stream &&
            (entry.classId != std::array<quint8,16>{} || entry.createdAt || entry.modifiedAt))
            throw std::runtime_error("Invalid stream metadata");
        total += quint64(entry.data.size());
        if (quint64(entry.data.size()) > kMaxStreamBytes || total > kMaxBytes)
            throw std::runtime_error("Oversized compound-file stream");
        Node node; node.entry = entry; node.name = names.back();
        node.type = entry.kind == CompoundFileEntry::Kind::Storage ? 1 : 2;
        paths.insert(entry.path, quint32(nodes.size())); nodes.push_back(std::move(node));
    }
    std::vector<std::vector<quint32>> children(nodes.size());
    for (quint32 i = 1; i < nodes.size(); ++i) {
        const auto path = nodes[i].entry.path;
        const auto slash = path.lastIndexOf('/');
        const auto parent = paths.constFind(slash < 0 ? QString() : path.left(slash));
        if (parent == paths.cend() || nodes[parent.value()].type == 2)
            throw std::runtime_error("Missing compound-file parent storage");
        children[parent.value()].push_back(i);
    }
    std::function<quint32(const std::vector<quint32>&,std::size_t,std::size_t)> tree;
    tree = [&](const auto& ids, std::size_t first, std::size_t last) -> quint32 {
        if (first == last) return kFree;
        const auto mid = first + (last - first) / 2;
        const auto id = ids[mid];
        nodes[id].left = tree(ids, first, mid); nodes[id].right = tree(ids, mid + 1, last);
        return id;
    };
    for (quint32 i = 0; i < nodes.size(); ++i) {
        auto& ids = children[i];
        std::sort(ids.begin(), ids.end(), [&](auto a,auto b) { return compareNames(nodes[a].name,nodes[b].name) < 0; });
        for (std::size_t j = 1; j < ids.size(); ++j)
            if (!compareNames(nodes[ids[j-1]].name,nodes[ids[j]].name))
                throw std::runtime_error("Case-equivalent compound-file siblings");
        // MS-CFB 2.6.4 explicitly permits all-black binary directory trees.
        // Balance their shape so sorted input cannot create a deep chain.
        nodes[i].child = tree(ids, 0, ids.size());
    }
    QByteArray data, mini;
    std::vector<quint32> allocation, miniAllocation;
    const auto allocate = [&](const QByteArray& bytes) -> quint32 {
        if (bytes.isEmpty()) return kEnd;
        const auto start = quint32(allocation.size()), count = blocks(bytes.size(),512);
        if (quint64(data.size()) + quint64(count)*512 > kMaxBytes)
            throw std::runtime_error("Oversized compound-file allocation");
        for (quint32 i = 0; i < count; ++i) allocation.push_back(i+1<count ? start+i+1 : kEnd);
        data += bytes; data += QByteArray(qsizetype(count)*512-bytes.size(),'\0');
        return start;
    };
    for (auto& node : nodes) {
        if (node.type != 2) continue;
        node.size = quint64(node.entry.data.size());
        if (!node.size) continue;
        if (node.size < 4096) {
            node.start = quint32(miniAllocation.size()); const auto count = blocks(node.size,64);
            for (quint32 i = 0; i < count; ++i) miniAllocation.push_back(i+1<count ? node.start+i+1 : kEnd);
            mini += node.entry.data; mini += QByteArray(qsizetype(count)*64-node.entry.data.size(),'\0');
        } else node.start = allocate(node.entry.data);
    }
    nodes[0].size = quint64(mini.size()); nodes[0].start = allocate(mini);
    QByteArray miniFat(qsizetype(blocks(quint64(miniAllocation.size())*4,512))*512,char(0xff));
    for (std::size_t i = 0; i < miniAllocation.size(); ++i) put(miniFat, qsizetype(i)*4,miniAllocation[i],4);
    const auto miniFatStart = allocate(miniFat);
    QByteArray directory(qsizetype(blocks(quint64(nodes.size())*128,512))*512,'\0');
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        const auto& node = nodes[i]; const auto at = qsizetype(i)*128;
        for (qsizetype c = 0; c < node.name.size(); ++c) put(directory,at+c*2,node.name[c].unicode(),2);
        put(directory,at+64,quint64(node.name.size()+1)*2,2); put(directory,at+66,node.type,1); put(directory,at+67,1,1);
        put(directory,at+68,node.left,4); put(directory,at+72,node.right,4); put(directory,at+76,node.child,4);
        for (int c = 0; c < 16; ++c) put(directory,at+80+c,node.entry.classId[std::size_t(c)],1);
        put(directory,at+96,node.entry.stateBits,4); put(directory,at+100,node.entry.createdAt,8);
        put(directory,at+108,node.entry.modifiedAt,8); put(directory,at+116,node.type==1 ? 0 : node.start,4);
        put(directory,at+120,node.size,8);
    }
    const auto directoryStart = allocate(directory), base = quint32(allocation.size());
    quint32 fatCount = 0, difatCount = 0;
    for (;;) {
        const auto nextFat = blocks(quint64(base+fatCount+difatCount)*4,512);
        const auto nextDifat = nextFat>109 ? blocks(nextFat-109,127) : 0;
        if (fatCount==nextFat && difatCount==nextDifat) break;
        fatCount=nextFat;difatCount=nextDifat;
    }
    if ((quint64(base)+fatCount+difatCount+1)*512 > kMaxBytes)
        throw std::runtime_error("Oversized compound-file container");
    for (quint32 i = 0; i < fatCount; ++i) allocation.push_back(kFat);
    for (quint32 i = 0; i < difatCount; ++i) allocation.push_back(kDifat);
    QByteArray fat(qsizetype(fatCount)*512,char(0xff));
    for (std::size_t i = 0; i < allocation.size(); ++i) put(fat,qsizetype(i)*4,allocation[i],4);
    data += fat;
    for (quint32 i = 0; i < difatCount; ++i) {
        QByteArray difat(512,char(0xff));
        for (quint32 j = 0; j < 127; ++j) {
            const auto index = 109+i*127+j;
            if (index<fatCount) put(difat,j*4,base+index,4);
        }
        put(difat,508,i+1<difatCount ? base+fatCount+i+1 : kEnd,4); data += difat;
    }
    QByteArray header(512,'\0'); header.replace(0,8,QByteArray::fromHex("d0cf11e0a1b11ae1"));
    put(header,24,0x3e,2);put(header,26,3,2);put(header,28,0xfffe,2);put(header,30,9,2);put(header,32,6,2);
    put(header,44,fatCount,4);put(header,48,directoryStart,4);put(header,56,4096,4);
    put(header,60,miniFatStart,4);put(header,64,quint64(miniFat.size())/512,4);
    put(header,68,difatCount ? base+fatCount : kEnd,4);put(header,72,difatCount,4);
    for (quint32 i = 0; i < 109; ++i) put(header,76+i*4,i<fatCount ? base+i : kFree,4);
    return header+data;
}

} // namespace

bool decodeCompoundFile(const QByteArray& bytes, CompoundFile& file, QString& error) {
    file={};error.clear();
    try { file=Decoder(bytes).decode(); return true; }
    catch (const std::exception& e) { error=failure(e); return false; }
}

bool encodeCompoundFile(const CompoundFile& file, QByteArray& bytes, QString& error) {
    bytes.clear();error.clear();
    try { bytes=encode(file); return true; }
    catch (const std::exception& e) { error=failure(e); return false; }
}

} // namespace cadnext::gui
