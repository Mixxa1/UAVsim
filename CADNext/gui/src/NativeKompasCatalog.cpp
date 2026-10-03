#include "cadnext/gui/NativeKompasCatalog.hpp"

#include <QObject>

#include <limits>
#include <map>
#include <set>
#include <stdexcept>

namespace cadnext::gui {
namespace {
constexpr quint64 kMaxBytes = 64ull*1024*1024;
constexpr quint64 kMaxNodes = 65535;
constexpr unsigned kMaxDepth = 64;
constexpr quint32 kMaxName = 4096;

void validateLocations(const std::vector<KompasRecordLocation>& records) {
    if(records.empty() || records.size()>8192)throw std::runtime_error("Invalid native record count");
    quint64 nextCluster=0;
    for(const auto& r:records) {
        if(r.compressedSize<=0 || r.clusterCount!=(quint64(r.compressedSize)+4095)/4096 ||
            r.firstCluster!=nextCluster || r.clusterCount>kMaxBytes/8 ||
            r.firstCluster>std::numeric_limits<quint64>::max()-r.clusterCount)
            throw std::runtime_error("Invalid native record locations");
        nextCluster+=r.clusterCount;
    }
}

class CatalogWriter {
public:
    CatalogWriter(const KompasCatalog& catalog, const std::vector<KompasRecordLocation>& records)
        : catalog_(catalog), records_(records), used_(records.size(), false) {validateLocations(records);}
    QByteArray encode() {
        if(catalog_.archiveSettings.size()!=6 || records_.empty()) fail("Invalid archive settings or empty record list");
        byte(0x80); word(0x3043); integer(catalog_.version); versions();
        bytes_+=catalog_.archiveSettings;
        entries(catalog_.entries,0,0); integer(catalog_.lastObjectId);
        for(bool used:used_) if(!used) fail("Native record has no catalog owner");
        return std::move(bytes_);
    }
private:
    const KompasCatalog& catalog_;
    const std::vector<KompasRecordLocation>& records_;
    std::vector<bool> used_;
    quint32 nextDirectory_ = 1;
    quint64 nodes_ = 0;
    QByteArray bytes_;
    [[noreturn]] static void fail(const char* message) {throw std::runtime_error(message);}
    void byte(quint8 n) {
        if(quint64(bytes_.size())>=kMaxBytes)fail("Catalog exceeds 64 MiB");
        bytes_.append(char(n));
    }
    void word(quint16 n) {byte(quint8(n));byte(quint8(n>>8));}
    void integer(quint32 n) {word(quint16(n));word(quint16(n>>16));}
    void count(quint64 n) {integer(quint32(n));integer(quint32(n>>32));}
    void versions() {
        if(catalog_.versions.empty() || catalog_.versions.size()>16 || catalog_.versions.front()!=catalog_.version)
            fail("Invalid catalog version vector");
        count(catalog_.versions.size());for(auto n:catalog_.versions)integer(n);
    }
    static QString key(const KompasCatalogEntry& e) {
        if(e.numericName && !e.textName.isEmpty()) fail("Catalog name cannot be numeric and textual together");
        const auto kind=e.directory?QStringLiteral("D"):QStringLiteral("F");
        if(e.numericName) return kind+QStringLiteral("N%1").arg(*e.numericName);
        if(e.textName.isEmpty() || e.textName.size()>kMaxName || e.textName.contains(QChar(u'\0')))
            fail("Invalid catalog text name");
        return kind+QStringLiteral("T")+e.textName;
    }
    void entries(const std::vector<KompasCatalogEntry>& items, quint16 parent, unsigned depth) {
        if(depth>kMaxDepth || items.size()>kMaxNodes)fail("Catalog directory limit exceeded");
        count(items.size());std::set<QString> names;
        for(const auto& e:items) {
            if(++nodes_>kMaxNodes || !names.insert(key(e)).second)fail("Duplicate name or catalog node limit exceeded");
            byte(2);byte(e.directory?0x80:0);word(e.directory?0x577f:0x4f1f);
            quint16 id=0;
            if(e.directory) {
                if(nextDirectory_>65535)fail("Catalog directory number overflow");
                id=quint16(nextDirectory_++);byte(1);word(id);integer(catalog_.version);
            }
            versions();byte(1);word(parent);byte(0);
            if(e.numericName) {byte(0);word(*e.numericName);}
            else {byte(2);integer(quint32(e.textName.size()));for(const auto c:e.textName)word(c.unicode());}
            if(e.directory) {byte(e.enabled);entries(e.children,id,depth+1);}
            else {
                if(!e.children.empty() || !e.enabled || e.recordIndex>=records_.size() || used_[e.recordIndex])
                    fail("Invalid or shared catalog record owner");
                used_[e.recordIndex]=true;
                const auto& r=records_[e.recordIndex];
                if(r.clusterCount==0 || e.position>r.compressedSize ||
                    r.firstCluster>std::numeric_limits<quint64>::max()-r.clusterCount)
                    fail("Invalid catalog record clusters or position");
                count(r.clusterCount);for(quint64 i=0;i<r.clusterCount;++i)count(r.firstCluster+i);
                word(e.position);
            }
            if(quint64(bytes_.size())>kMaxBytes)fail("Catalog exceeds 64 MiB");
        }
    }
};

class CatalogReader {
public:
    CatalogReader(const QByteArray& bytes,const std::vector<KompasRecordLocation>& records)
        : bytes_(bytes),records_(records),used_(records.size(),false) {
        validateLocations(records);
        for(std::size_t i=0;i<records.size();++i) {
            const auto& r=records[i];
            if(!r.clusterCount || r.firstCluster>std::numeric_limits<quint64>::max()-r.clusterCount ||
                !firstCluster_.emplace(r.firstCluster,i).second)fail("Invalid native record locations");
        }
    }
    KompasCatalog decode() {
        if(bytes_.isEmpty() || quint64(bytes_.size())>kMaxBytes || records_.empty())fail("Invalid catalog size or empty record list");
        if(byte()!=0x80 || word()!=0x3043)fail("Unsupported native catalog class");
        catalog_.version=integer();catalog_.versions=versions();
        if(catalog_.versions.front()!=catalog_.version)fail("Catalog root version mismatch");
        take(6);catalog_.archiveSettings=bytes_.mid(at_-6,6);
        catalog_.entries=entries(0,0);catalog_.lastObjectId=integer();
        if(at_!=bytes_.size())fail("Trailing catalog bytes");
        for(bool used:used_)if(!used)fail("Native record has no catalog owner");
        return std::move(catalog_);
    }
private:
    const QByteArray& bytes_;
    const std::vector<KompasRecordLocation>& records_;
    std::vector<bool> used_;
    std::map<quint64,std::size_t> firstCluster_;
    std::set<quint16> directoryIds_{0};
    qsizetype at_=0;
    quint64 nodes_=0;
    KompasCatalog catalog_;
    [[noreturn]] static void fail(const char* message) {throw std::runtime_error(message);}
    void take(qsizetype n) {
        if(n<0 || n>bytes_.size()-at_)fail("Truncated native catalog");at_+=n;
    }
    quint8 byte() {take(1);return quint8(bytes_[at_-1]);}
    quint16 word() {const auto a=byte();return quint16(a | quint16(byte())<<8);}
    quint32 integer() {const auto a=word();return quint32(a) | quint32(word())<<16;}
    quint64 count() {const auto a=integer();return quint64(a) | quint64(integer())<<32;}
    std::vector<quint32> versions() {
        const auto n=count();if(!n || n>16)fail("Invalid catalog version vector");
        std::vector<quint32> v;for(quint64 i=0;i<n;++i)v.push_back(integer());return v;
    }
    std::vector<KompasCatalogEntry> entries(quint16 parent,unsigned depth) {
        const auto n=count();
        if(depth>kMaxDepth || n>kMaxNodes-nodes_ || n>quint64(bytes_.size()-at_)/32)
            fail("Catalog directory limit exceeded");
        std::vector<KompasCatalogEntry> result;std::set<QString> names;
        for(quint64 i=0;i<n;++i) {
            ++nodes_;KompasCatalogEntry e;
            if(byte()!=2)fail("Unsupported catalog pointer");
            const auto flag=byte();const auto cls=word();
            quint16 id=0;
            if(flag==0x80 && cls==0x577f) {
                e.directory=true;
                if(byte()!=1)fail("Invalid catalog directory registration");
                id=word();if(!directoryIds_.insert(id).second)fail("Duplicate catalog directory number");
                if(integer()!=catalog_.version)fail("Catalog directory version mismatch");
            } else if(flag!=0 || cls!=0x4f1f)fail("Unsupported catalog entry class");
            if(versions()!=catalog_.versions)fail("Catalog entry version mismatch");
            if(byte()!=1 || word()!=parent || byte()!=0)fail("Invalid catalog parent or name flags");
            const auto type=byte();QString key;
            if(type==0) {e.numericName=word();key=QStringLiteral("N%1").arg(*e.numericName);}
            else if(type==2) {
                const auto length=integer();if(!length || length>kMaxName)fail("Invalid catalog text name length");
                for(quint32 j=0;j<length;++j)e.textName+=QChar(word());
                if(e.textName.contains(QChar(u'\0')))fail("Embedded zero in catalog name");
                key=QStringLiteral("T")+e.textName;
            } else fail("Unsupported catalog name type");
            // Native directories and streams have separate name spaces. An
            // assembly can own a stream and a directory with the same name.
            if(!names.insert((e.directory?QStringLiteral("D"):QStringLiteral("F"))+key).second)
                fail("Duplicate catalog name");
            if(e.directory) {
                const auto enabled=byte();if(enabled>1)fail("Invalid catalog directory state");
                e.enabled=enabled;e.children=entries(id,depth+1);
            } else {
                const auto clusters=count();if(!clusters || clusters>quint64(bytes_.size()-at_)/8)
                    fail("Invalid catalog cluster count");
                const auto first=count();const auto found=firstCluster_.find(first);
                if(found==firstCluster_.end())fail("Catalog refers to a nonexistent record");
                e.recordIndex=found->second;const auto& r=records_[e.recordIndex];
                if(used_[e.recordIndex] || clusters!=r.clusterCount)fail("Shared or incomplete catalog record");
                used_[e.recordIndex]=true;
                for(quint64 j=1;j<clusters;++j)if(count()!=first+j)fail("Nonconsecutive catalog record clusters");
                e.position=word();if(e.position>r.compressedSize)fail("Invalid catalog stream position");
            }
            result.push_back(std::move(e));
        }
        return result;
    }
};
} // namespace

bool encodeKompasCatalog(const KompasCatalog& catalog,const KompasStoragePrefix& prefix,
                         QByteArray& bytes,QString& error) {
    bytes.clear();error.clear();
    try {bytes=CatalogWriter(catalog,prefix.records).encode();return true;}
    catch(const std::exception& e) {error=QObject::tr("Каталог КОМПАС: %1").arg(QString::fromUtf8(e.what()));return false;}
}
bool decodeKompasCatalog(const QByteArray& bytes,const std::vector<KompasRecordLocation>& records,
                         KompasCatalog& catalog,QString& error) {
    catalog={};error.clear();
    try {catalog=CatalogReader(bytes,records).decode();return true;}
    catch(const std::exception& e) {error=QObject::tr("Каталог КОМПАС: %1").arg(QString::fromUtf8(e.what()));return false;}
}
} // namespace cadnext::gui
