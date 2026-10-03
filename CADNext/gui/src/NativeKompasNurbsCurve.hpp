#pragma once

#include <QByteArray>
#include <QString>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace cadnext::gui::detail {

// Native MbNurbs (0x7505) data, without its pointer/class/registry envelope.
// Counts store the last index; the five cache values precede the closed flag.
struct KompasNurbs2 {
    std::vector<std::array<double, 2>> poles;
    std::array<double, 5> cache{-1, 1e300, 1e300, -1e300, -1e300};
    bool closed = false;
    quint64 order = 0;
    std::array<quint8, 2> nativeFlags{};
    std::vector<double> weights;
    std::vector<double> knots;
};

inline constexpr quint64 kKompasNurbsPoleLimit=1000000;

inline void validateKompasNurbs2(const KompasNurbs2& c) {
    const auto n = c.poles.size();
    if (n < 2 || n > kKompasNurbsPoleLimit || c.order < 2 || c.order > 26 || c.order > n ||
        c.weights.size() != n || c.knots.size() != n + (c.closed ? 2*c.order-1 : c.order))
        throw std::runtime_error("Invalid C3D UV NURBS sizes");
    if ((c.nativeFlags[0] != 0 && c.nativeFlags[0] != 7) || c.nativeFlags[1] != 0)
        throw std::runtime_error("Unsupported C3D UV NURBS flags");
    for (const auto& pole : c.poles)
        for (const auto v : pole)
            if (!std::isfinite(v)) throw std::runtime_error("Non-finite C3D UV pole");
    for (const auto v : c.cache)
        if (!std::isfinite(v)) throw std::runtime_error("Non-finite C3D UV cache");
    if (c.cache[0] < 0 && c.cache[0] != -1)
        throw std::runtime_error("Invalid C3D UV metric cache");
    const std::array<double,5> empty{-1,1e300,1e300,-1e300,-1e300};
    if ((c.cache[1] > c.cache[3] || c.cache[2] > c.cache[4]) &&
        !(c.cache[1]==empty[1] && c.cache[2]==empty[2] && c.cache[3]==empty[3] && c.cache[4]==empty[4]))
        throw std::runtime_error("Inverted C3D UV cache box");
    for (const auto v : c.weights)
        if (!std::isfinite(v) || v <= 0) throw std::runtime_error("Invalid C3D UV weight");
    for (std::size_t i=0;i<c.knots.size();++i)
        if (!std::isfinite(c.knots[i]) || (i && c.knots[i]<c.knots[i-1]))
            throw std::runtime_error("Invalid C3D UV knot vector");
    const auto last = n + (c.closed ? c.order-1 : 0);
    if (!(c.knots[last] > c.knots[c.order-1]))
        throw std::runtime_error("Empty C3D UV NURBS domain");
    std::size_t multiplicity=0;
    for (std::size_t i=0;i<c.knots.size();++i) {
        multiplicity=i && c.knots[i]==c.knots[i-1] ? multiplicity+1 : 1;
        if (multiplicity>c.order) throw std::runtime_error("Excessive C3D UV knot multiplicity");
    }
}

inline bool decodeKompasNurbs2Data(const QByteArray& bytes, qsizetype offset,
                                  KompasNurbs2& curve, qsizetype& consumed, QString& error) {
    curve={}; consumed=0; error.clear();
    KompasNurbs2 staged;
    qsizetype at=offset;
    try {
        if (at<0 || at>bytes.size()) throw std::runtime_error("Invalid C3D UV offset");
        const auto number=[&](int width) {
            if (width>bytes.size()-at) throw std::runtime_error("Truncated C3D UV NURBS");
            quint64 value=0;
            for(int i=0;i<width;++i)value|=quint64(uchar(bytes[at++]))<<(8*i);
            return value;
        };
        const auto real=[&] {
            const auto bits=number(8);double value;std::memcpy(&value,&bits,8);
            if(!std::isfinite(value))throw std::runtime_error("Non-finite C3D UV value");
            return value;
        };
        const auto lastIndex=number(8);
        if(lastIndex<1 || lastIndex>=kKompasNurbsPoleLimit)throw std::runtime_error("Invalid C3D UV pole count");
        const auto n=std::size_t(lastIndex+1);
        if(quint64(bytes.size()-at)<16*n+59)throw std::runtime_error("Truncated C3D UV poles");
        staged.poles.resize(n);
        for(auto& pole:staged.poles)for(auto& v:pole)v=real();
        for(auto& v:staged.cache)v=real();
        const auto closed=number(1);
        if(closed>1)throw std::runtime_error("Invalid C3D UV closure flag");
        staged.closed=closed!=0;staged.order=number(8);
        const auto lastKnot=number(8);
        if(lastKnot>kKompasNurbsPoleLimit+50)throw std::runtime_error("Oversized C3D UV knots");
        for(auto& v:staged.nativeFlags)v=quint8(number(1));
        if(quint64(bytes.size()-at)<8*(n+lastKnot+1))throw std::runtime_error("Truncated C3D UV weights/knots");
        staged.weights.resize(n);staged.knots.resize(std::size_t(lastKnot+1));
        for(auto& v:staged.weights)v=real();
        for(auto& v:staged.knots)v=real();
        validateKompasNurbs2(staged);
    } catch(const std::exception& e) {error=QString::fromUtf8(e.what());return false;}
    curve=std::move(staged);consumed=at-offset;return true;
}

inline bool encodeKompasNurbs2Data(const KompasNurbs2& curve, QByteArray& bytes, QString& error) {
    bytes.clear();error.clear();QByteArray staged;
    try {
        validateKompasNurbs2(curve);
        const auto number=[&](quint64 value,int width) {for(int i=0;i<width;++i)staged.append(char((value>>(8*i))&255));};
        const auto real=[&](double value) {quint64 bits;std::memcpy(&bits,&value,8);number(bits,8);};
        number(curve.poles.size()-1,8);
        for(const auto& pole:curve.poles)for(const auto v:pole)real(v);
        for(const auto v:curve.cache)real(v);
        number(curve.closed,1);number(curve.order,8);number(curve.knots.size()-1,8);
        for(const auto v:curve.nativeFlags)number(v,1);
        for(const auto v:curve.weights)real(v);
        for(const auto v:curve.knots)real(v);
    } catch(const std::exception& e) {error=QString::fromUtf8(e.what());return false;}
    bytes=std::move(staged);return true;
}

// A closed native spline uses cyclic poles with an extended knot vector.
// Appending the first degree poles gives the same polynomial basis as an open
// representation, over its original active parameter range.
inline KompasNurbs2 unwrapKompasNurbs2(KompasNurbs2 c) {
    validateKompasNurbs2(c);
    if(c.closed) {
        const auto degree=std::size_t(c.order-1);
        const auto poles=c.poles;const auto weights=c.weights;
        for(std::size_t i=0;i<degree;++i) {c.poles.push_back(poles[i]);c.weights.push_back(weights[i]);}
        c.closed=false;
    }
    return c;
}

inline std::array<double,2> pointOnKompasNurbs2(const KompasNurbs2& native,double t) {
    const auto c=unwrapKompasNurbs2(native);
    const auto p=std::size_t(c.order-1),n=c.poles.size();
    const auto first=c.knots[p],last=c.knots[n];
    if(!std::isfinite(t) || t<first || t>last)throw std::runtime_error("C3D UV parameter outside NURBS domain");
    auto span=t==last ? n-1 : std::size_t(std::upper_bound(c.knots.begin(),c.knots.end(),t)-c.knots.begin()-1);
    while(span>p && c.knots[span]==c.knots[span+1])--span;
    std::vector<std::array<double,3>> d(p+1);
    for(std::size_t j=0;j<=p;++j) {
        const auto i=span-p+j;
        const auto w=c.weights[i];
        d[j]={c.poles[i][0]*w,c.poles[i][1]*w,w};
    }
    for(std::size_t r=1;r<=p;++r)
        for(std::size_t j=p;j>=r;--j) {
            const auto i=span-p+j;
            const double den=c.knots[i+p-r+1]-c.knots[i];
            const double a=den>0 ? (t-c.knots[i])/den : 0;
            for(int k=0;k<3;++k)d[j][k]=(1-a)*d[j-1][k]+a*d[j][k];
        }
    if(!(d[p][2]>0))throw std::runtime_error("Invalid C3D UV homogeneous point");
    return {d[p][0]/d[p][2],d[p][1]/d[p][2]};
}

inline std::array<double,2> derivativeOnKompasNurbs2(const KompasNurbs2& native,double t) {
    const auto c=unwrapKompasNurbs2(native);
    const auto p=std::size_t(c.order-1),n=c.poles.size();
    if(!std::isfinite(t) || t<c.knots[p] || t>c.knots[n])
        throw std::runtime_error("C3D UV parameter outside NURBS domain");
    // Differentiate homogeneous control points, then apply the quotient rule.
    std::vector<std::array<double,3>> h(n),dh(n-1);
    for(std::size_t i=0;i<n;++i)h[i]={c.poles[i][0]*c.weights[i],c.poles[i][1]*c.weights[i],c.weights[i]};
    for(std::size_t i=0;i+1<n;++i) {
        const double span=c.knots[i+p+1]-c.knots[i+1];
        for(int k=0;k<3;++k)dh[i][k]=span>0 ? p*(h[i+1][k]-h[i][k])/span : 0;
    }
    const auto value=[&](const auto& poles,const auto& knots,std::size_t degree) {
        const auto count=poles.size();
        auto span=t==knots[count] ? count-1 :
            std::size_t(std::upper_bound(knots.begin(),knots.end(),t)-knots.begin()-1);
        while(span>degree && knots[span]==knots[span+1])--span;
        std::vector<std::array<double,3>> d(degree+1);
        for(std::size_t j=0;j<=degree;++j)d[j]=poles[span-degree+j];
        for(std::size_t r=1;r<=degree;++r)for(std::size_t j=degree;j>=r;--j) {
            const auto i=span-degree+j;
            const double den=knots[i+degree-r+1]-knots[i];
            const double a=den>0 ? (t-knots[i])/den : 0;
            for(int k=0;k<3;++k)d[j][k]=(1-a)*d[j-1][k]+a*d[j][k];
        }
        return d[degree];
    };
    const auto at=value(h,c.knots,p);
    const std::vector<double> derivativeKnots(c.knots.begin()+1,c.knots.end()-1);
    const auto tangent=value(dh,derivativeKnots,p-1);
    if(!(at[2]>0))throw std::runtime_error("Invalid C3D UV homogeneous point");
    return {(tangent[0]-at[0]/at[2]*tangent[2])/at[2],
            (tangent[1]-at[1]/at[2]*tangent[2])/at[2]};
}

// Exact rational knot insertion at the two endpoints, then discard the
// portions outside the interval. This changes neither the curve nor its law.
inline KompasNurbs2 restrictKompasNurbs2(KompasNurbs2 c,double lo,double hi) {
    c=unwrapKompasNurbs2(std::move(c));
    const auto p=std::size_t(c.order-1);
    if(!std::isfinite(lo) || !std::isfinite(hi) || !(hi>lo) ||
       lo<c.knots[p] || hi>c.knots[c.poles.size()])throw std::runtime_error("Invalid C3D UV restriction");
    for(const auto t:{lo,hi}) {
        auto s=std::size_t(std::count(c.knots.begin(),c.knots.end(),t));
        while(s<c.order) {
            const auto n=c.poles.size();
            const auto k=std::size_t(std::upper_bound(c.knots.begin(),c.knots.end(),t)-c.knots.begin()-1);
            // At an unclamped active endpoint the last matching knot can be
            // past the last pole. Its existing multiplicity still leaves all
            // copied and blended controls in range; clamping k changes the curve.
            if(k<p || k-p>=n || k-s>=n)throw std::runtime_error("Unsupported C3D UV endpoint insertion");
            std::vector<std::array<double,3>> h(n),out(n+1);
            for(std::size_t i=0;i<n;++i)h[i]={c.poles[i][0]*c.weights[i],c.poles[i][1]*c.weights[i],c.weights[i]};
            for(std::size_t i=0;i<=k-p;++i)out[i]=h[i];
            for(std::size_t i=k-s;i<n;++i)out[i+1]=h[i];
            for(std::size_t i=k-p+1;i<=k-s;++i) {
                const double den=c.knots[i+p]-c.knots[i];
                if(!(den>0))throw std::runtime_error("Invalid C3D UV insertion span");
                const double a=(t-c.knots[i])/den;
                for(int j=0;j<3;++j)out[i][j]=(1-a)*h[i-1][j]+a*h[i][j];
            }
            c.poles.resize(n+1);c.weights.resize(n+1);
            for(std::size_t i=0;i<=n;++i) {
                c.weights[i]=out[i][2];c.poles[i]={out[i][0]/out[i][2],out[i][1]/out[i][2]};
            }
            c.knots.insert(c.knots.begin()+std::ptrdiff_t(k+1),t);++s;
        }
    }
    const auto a=std::size_t(std::lower_bound(c.knots.begin(),c.knots.end(),lo)-c.knots.begin());
    const auto b=std::size_t(std::lower_bound(c.knots.begin(),c.knots.end(),hi)-c.knots.begin());
    c.poles=std::vector<std::array<double,2>>(c.poles.begin()+std::ptrdiff_t(a),c.poles.begin()+std::ptrdiff_t(b));
    c.weights=std::vector<double>(c.weights.begin()+std::ptrdiff_t(a),c.weights.begin()+std::ptrdiff_t(b));
    c.knots=std::vector<double>(c.knots.begin()+std::ptrdiff_t(a),c.knots.begin()+std::ptrdiff_t(b+c.order));
    c.cache={-1,1e300,1e300,-1e300,-1e300};
    validateKompasNurbs2(c);return c;
}

} // namespace cadnext::gui::detail
