#include "cadnext/gui/NativeCompoundFile.hpp"

#include <QMap>

#include <cassert>

namespace {
void put(QByteArray& bytes,qsizetype at,quint64 value,int count=4) {
    for(int i=0;i<count;++i)bytes[at+i]=char((value>>(8*i))&0xff);
}
quint32 u32(const QByteArray& bytes,qsizetype at) {
    return quint32(uchar(bytes[at]))|quint32(uchar(bytes[at+1]))<<8|
           quint32(uchar(bytes[at+2]))<<16|quint32(uchar(bytes[at+3]))<<24;
}
void name(QByteArray& bytes,qsizetype at,const QString& value) {
    for(qsizetype i=0;i<value.size();++i)put(bytes,at+2*i,value[i].unicode(),2);
    put(bytes,at+64,(value.size()+1)*2,2);
}
// A hand-authored CFB v3 file: FAT at 0, directory at 1, MiniFAT at 2,
// a two-sector mini stream at 3/4, and one 544-byte stream under a storage.
// Its chains and physical sector locations are independent of the writer.
QByteArray fixture() {
    constexpr quint32 end=0xfffffffe,free=0xffffffff;
    QByteArray bytes(6*512,'\0');
    bytes.replace(0,8,QByteArray::fromHex("d0cf11e0a1b11ae1"));
    put(bytes,24,0x003e,2);put(bytes,26,3,2);put(bytes,28,0xfffe,2);put(bytes,30,9,2);put(bytes,32,6,2);
    put(bytes,44,1);put(bytes,48,1);put(bytes,56,4096);put(bytes,60,2);put(bytes,64,1);put(bytes,68,end);
    for(int i=1;i<109;++i)put(bytes,76+4*i,free);
    for(int i=0;i<128;++i)put(bytes,512+4*i,free);
    put(bytes,512,0xfffffffd);put(bytes,516,end);put(bytes,520,end);put(bytes,524,4);put(bytes,528,end);
    for(int i=0;i<3;++i) {
        const auto at=1024+128*i;
        put(bytes,at+67,1,1);put(bytes,at+68,free);put(bytes,at+72,free);put(bytes,at+76,free);
    }
    name(bytes,1024,"Root Entry");put(bytes,1090,5,1);put(bytes,1100,1);put(bytes,1140,3);put(bytes,1144,576,8);
    name(bytes,1152,"Storage 1");put(bytes,1218,1,1);put(bytes,1228,2);
    name(bytes,1280,"Stream 1");put(bytes,1346,2,1);put(bytes,1400,544,8);
    for(int i=0;i<128;++i)put(bytes,1536+4*i,i<8 ? quint32(i+1) : i==8 ? end : free);
    for(int i=0;i<544;++i)bytes[2048+i]=char(i%251);
    return bytes;
}
QMap<QString,QByteArray> streams(const cadnext::gui::CompoundFile& file) {
    QMap<QString,QByteArray> result;
    for(const auto& entry:file.entries)
        if(entry.kind==cadnext::gui::CompoundFileEntry::Kind::Stream)result.insert(entry.path,entry.data);
    return result;
}
}

int main() {
    using namespace cadnext::gui;
    const auto original=fixture();QString error;CompoundFile decoded;
    assert(decodeCompoundFile(original,decoded,error));
    assert(decoded.entries.size()==2 && decoded.entries[0].kind==CompoundFileEntry::Kind::Storage);
    QByteArray expected(544,Qt::Uninitialized);
    for(int i=0;i<544;++i)expected[i]=char(i%251);
    assert(streams(decoded).value("Storage 1/Stream 1")==expected);
    // The same hand-authored objects with 4096-byte sectors (CFB v4).
    QByteArray version4(6*4096,'\0');version4.replace(0,512,original.left(512));
    put(version4,26,4,2);put(version4,30,12,2);put(version4,40,1);
    for(int i=0;i<1024;++i)put(version4,4096+4*i,0xffffffff);
    version4.replace(4096,512,original.mid(512,512));
    put(version4,4096+12,0xfffffffe);put(version4,4096+16,0xffffffff);
    version4.replace(8192,512,original.mid(1024,512));
    for(int i=0;i<1024;++i)put(version4,12288+4*i,0xffffffff);
    version4.replace(12288,512,original.mid(1536,512));
    version4.replace(16384,576,original.mid(2048,576));
    CompoundFile v4Read;assert(decodeCompoundFile(version4,v4Read,error));
    assert(streams(v4Read)==streams(decoded));
    // A fragmented MiniFAT chain: swap mini sectors 1 and 2 physically and
    // update their links. Logical bytes must remain unchanged.
    auto fragmented=original;
    fragmented.replace(2112,64,original.mid(2176,64));
    fragmented.replace(2176,64,original.mid(2112,64));
    put(fragmented,1536,2);put(fragmented,1544,1);put(fragmented,1540,3);
    CompoundFile fragmentedRead;
    assert(decodeCompoundFile(fragmented,fragmentedRead,error));
    assert(streams(fragmentedRead)==streams(decoded));
    // CFB v3 readers ignore historical garbage in the high size DWORD.
    auto legacy=original;put(legacy,1404,0x76543210);
    assert(decodeCompoundFile(legacy,fragmentedRead,error));
    assert(streams(fragmentedRead)==streams(decoded));
    QByteArray encoded;assert(encodeCompoundFile(decoded,encoded,error));
    CompoundFile reread;assert(decodeCompoundFile(encoded,reread,error));
    assert(streams(reread)==streams(decoded));
    auto reject=[&](const QByteArray& bad) {
        CompoundFile output=decoded;
        assert(!decodeCompoundFile(bad,output,error));
        assert(output.entries.empty() && !error.isEmpty());
    };
    for(qsizetype at=0;at<original.size();at+=31)reject(original.left(at));
    for(const auto change:std::initializer_list<std::pair<qsizetype,quint32>>{
            {28,0},{30,12},{32,5},{44,2},{48,999},{56,2048},{60,1},{64,2},{68,0},
            {512,0xfffffffe},{524,3},{528,999},{532,0},{1100,0},{1228,1},{1346,5},
            {1348,2},{1356,1},{1400,700},{1536,0},{1540,0xfffffffe}}) {
        auto bad=original;put(bad,change.first,change.second);reject(bad);
    }
    auto badName=original;put(badName,1344,66,2);reject(badName);
    auto badColor=original;put(badColor,1347,2,1);reject(badColor);
    // Independent long stream with a non-contiguous normal FAT chain.
    auto normal=original;
    normal.resize(14*512);normal.fill('\0',14*512);
    normal.replace(0,3072,original);
    put(normal,1400,4096,8);put(normal,1396,5);
    put(normal,1090,5,1);put(normal,1140,0xfffffffe);put(normal,1144,0,8);
    put(normal,60,0xfffffffe);put(normal,64,0);
    for(int i=2;i<13;++i)put(normal,512+4*i,0xffffffff);
    const int chain[]={5,7,6,8,9,10,11,12};
    QByteArray longExpected;
    for(int i=0;i<8;++i) {
        put(normal,512+4*chain[i],i<7 ? quint32(chain[i+1]) : 0xfffffffe);
        const QByteArray chunk(512,char('A'+i));normal.replace((chain[i]+1)*512,512,chunk);longExpected+=chunk;
    }
    assert(decodeCompoundFile(normal,reread,error));
    assert(streams(reread).value("Storage 1/Stream 1")==longExpected);
    CompoundFile document;document.rootClassId[0]=0x25;document.rootStateBits=7;document.rootModifiedAt=42;
    document.entries.push_back({"Contents",CompoundFileEntry::Kind::Storage});
    document.entries.back().classId[2]=0xc3;document.entries.back().createdAt=123;
    document.entries.push_back({"Empty",CompoundFileEntry::Kind::Storage});
    for(int size:{0,1,63,64,65,4095,4096,4097,8192}) {
        const auto path="Contents/N"+QString::number(size);
        document.entries.push_back({path,CompoundFileEntry::Kind::Stream,QByteArray(size,char(size%127))});
    }
    document.entries.push_back({QString::fromUtf8("Contents/Имя😀"),CompoundFileEntry::Kind::Stream,"Unicode"});
    document.entries.push_back({QString(QChar(5))+"SummaryInformation",CompoundFileEntry::Kind::Stream,"Property set"});
    assert(encodeCompoundFile(document,encoded,error));
    assert(decodeCompoundFile(encoded,reread,error));
    assert(reread.entries.size()==document.entries.size() && streams(reread)==streams(document));
    assert(reread.rootClassId==document.rootClassId && reread.rootStateBits==7 && reread.rootModifiedAt==42);
    for(const auto& entry:reread.entries)if(entry.path=="Contents")assert(entry.classId[2]==0xc3 && entry.createdAt==123);
    // Enough data to exhaust the 109 FAT locations in the header and require DIFAT.
    document.entries.push_back({"Large",CompoundFileEntry::Kind::Stream,QByteArray(8*1024*1024,'z')});
    assert(encodeCompoundFile(document,encoded,error));
    assert(u32(encoded,44)>109 && u32(encoded,72)==1);
    assert(decodeCompoundFile(encoded,reread,error) && streams(reread)==streams(document));
    auto difatCycle=encoded;put(difatCycle,(quint64(u32(encoded,68))+1)*512+508,u32(encoded,68));reject(difatCycle);
    for(const auto path:QStringList{"Contents/missing/x","Contents/","Contents/..",QString(32,'x'),"Contents/X!"}) {
        auto bad=document;bad.entries.push_back({path,CompoundFileEntry::Kind::Stream,"x"});
        QByteArray output="old";assert(!encodeCompoundFile(bad,output,error) && output.isEmpty() && !error.isEmpty());
    }
    auto duplicate=document;duplicate.entries.push_back({"contents",CompoundFileEntry::Kind::Storage});
    assert(!encodeCompoundFile(duplicate,encoded,error) && encoded.isEmpty());
    auto badParent=document;badParent.entries.push_back({"Large/x",CompoundFileEntry::Kind::Stream,"x"});
    assert(!encodeCompoundFile(badParent,encoded,error) && encoded.isEmpty());
    auto badMetadata=document;badMetadata.entries.back().createdAt=123;
    assert(!encodeCompoundFile(badMetadata,encoded,error) && encoded.isEmpty());
    CompoundFile empty;assert(encodeCompoundFile(empty,encoded,error));
    assert(decodeCompoundFile(encoded,reread,error) && reread.entries.empty());
}
