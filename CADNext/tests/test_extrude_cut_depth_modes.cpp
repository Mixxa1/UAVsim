#include "cadnext/ExtrudeCut.hpp"

#include <cassert>
#include <cmath>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

cadnext::ExtrudeCutParameters baseParameters() {
    cadnext::ExtrudeCutParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.sketchId = "sketch-1";
    parameters.profileId = "profile-1";
    parameters.distance = 2.0;
    return parameters;
}

cadnext::CutExtents baseExtents() {
    cadnext::CutExtents extents;
    extents.targetMin = -1.0;
    extents.targetMax = 2.0;
    extents.targetDiagonal = 3.0;
    return extents;
}

} // namespace

int main() {
    cadnext::ExtrudeCutParameters parameters = baseParameters();
    cadnext::CutExtents extents = baseExtents();

    cadnext::Result<cadnext::CutSpan> span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(nearlyEqual(span.value().start, 0.0));
    assert(nearlyEqual(span.value().end, 2.0));

    parameters.direction = cadnext::CutDirection::Negative;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(nearlyEqual(span.value().start, -2.0));
    assert(nearlyEqual(span.value().end, 0.0));

    parameters.direction = cadnext::CutDirection::Symmetric;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(nearlyEqual(span.value().start, -1.0));
    assert(nearlyEqual(span.value().end, 1.0));

    parameters = baseParameters();
    parameters.depthMode = cadnext::CutDepthMode::ThroughAll;
    parameters.direction = cadnext::CutDirection::Positive;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(nearlyEqual(span.value().start, 0.0));
    assert(span.value().end > extents.targetMax + extents.targetDiagonal);

    parameters.direction = cadnext::CutDirection::Negative;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(span.value().start < extents.targetMin - extents.targetDiagonal);
    assert(nearlyEqual(span.value().end, 0.0));

    parameters.direction = cadnext::CutDirection::Symmetric;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(span.value().start < extents.targetMin - extents.targetDiagonal);
    assert(span.value().end > extents.targetMax + extents.targetDiagonal);

    parameters = baseParameters();
    parameters.depthMode = cadnext::CutDepthMode::ToObject;
    parameters.direction = cadnext::CutDirection::Positive;
    parameters.limitObjectId = "body-2";
    extents.hasLimit = true;
    extents.limitMin = 4.5;
    extents.limitMax = 6.0;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(nearlyEqual(span.value().start, 0.0));
    assert(nearlyEqual(span.value().end, 4.5));

    extents.limitMin = -3.0;
    extents.limitMax = -1.0;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(!span.isOk());

    parameters.direction = cadnext::CutDirection::Negative;
    span = cadnext::computeCutSpan(parameters, extents);
    assert(span.isOk());
    assert(nearlyEqual(span.value().start, -1.0));
    assert(nearlyEqual(span.value().end, 0.0));

    return 0;
}
