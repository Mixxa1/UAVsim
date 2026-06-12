#include "cadnext/Document.hpp"

#include <algorithm>
#include <utility>

namespace cadnext {

Document::Document()
    : id_("document"), name_("Untitled CADNext Document") {}

const std::string& Document::id() const { return id_; }

void Document::setId(std::string id) { id_ = std::move(id); }

const std::string& Document::name() const { return name_; }

void Document::setName(std::string name) { name_ = std::move(name); }

UnitSystem Document::unitSystem() const { return units_; }

void Document::setUnitSystem(UnitSystem units) { units_ = units; }

void Document::addObject(Object object) { objects_.push_back(std::move(object)); }

bool Document::removeObject(const std::string& objectId) {
    auto it = std::find_if(objects_.begin(), objects_.end(), [&](const Object& object) {
        return object.id == objectId;
    });
    if (it == objects_.end()) {
        return false;
    }
    objects_.erase(it);
    return true;
}

Result<Object> Document::objectById(const std::string& objectId) const {
    auto it = std::find_if(objects_.begin(), objects_.end(), [&](const Object& object) {
        return object.id == objectId;
    });
    if (it == objects_.end()) {
        return Result<Object>::fail({ErrorCode::NotFound, "Object not found: " + objectId});
    }
    return Result<Object>::ok(*it);
}

Object* Document::mutableObjectById(const std::string& objectId) {
    auto it = std::find_if(objects_.begin(), objects_.end(), [&](const Object& object) {
        return object.id == objectId;
    });
    if (it == objects_.end()) {
        return nullptr;
    }
    return &*it;
}

void Document::addSketch(Sketch sketch) { sketches_.push_back(std::move(sketch)); }

bool Document::removeSketch(const std::string& sketchId) {
    auto it = std::find_if(sketches_.begin(), sketches_.end(), [&](const Sketch& sketch) {
        return sketch.id == sketchId;
    });
    if (it == sketches_.end()) {
        return false;
    }
    sketches_.erase(it);
    return true;
}

Result<Sketch> Document::sketchById(const std::string& sketchId) const {
    auto it = std::find_if(sketches_.begin(), sketches_.end(), [&](const Sketch& sketch) {
        return sketch.id == sketchId;
    });
    if (it == sketches_.end()) {
        return Result<Sketch>::fail({ErrorCode::NotFound, "Sketch not found: " + sketchId});
    }
    return Result<Sketch>::ok(*it);
}

Sketch* Document::mutableSketchById(const std::string& sketchId) {
    auto it = std::find_if(sketches_.begin(), sketches_.end(), [&](const Sketch& sketch) {
        return sketch.id == sketchId;
    });
    if (it == sketches_.end()) {
        return nullptr;
    }
    return &*it;
}

const std::vector<Sketch>& Document::sketches() const { return sketches_; }

void Document::addWorkPlane(WorkPlane plane) { workPlanes_.push_back(std::move(plane)); }

bool Document::removeWorkPlane(const std::string& planeId) {
    auto it = std::find_if(workPlanes_.begin(), workPlanes_.end(),
                           [&](const WorkPlane& plane) { return plane.id == planeId; });
    if (it == workPlanes_.end()) {
        return false;
    }
    workPlanes_.erase(it);
    return true;
}

Result<WorkPlane> Document::workPlaneById(const std::string& planeId) const {
    auto it = std::find_if(workPlanes_.begin(), workPlanes_.end(),
                           [&](const WorkPlane& plane) { return plane.id == planeId; });
    if (it == workPlanes_.end()) {
        return Result<WorkPlane>::fail(
            {ErrorCode::NotFound, "Work plane not found: " + planeId});
    }
    return Result<WorkPlane>::ok(*it);
}

WorkPlane* Document::mutableWorkPlaneById(const std::string& planeId) {
    auto it = std::find_if(workPlanes_.begin(), workPlanes_.end(),
                           [&](const WorkPlane& plane) { return plane.id == planeId; });
    if (it == workPlanes_.end()) {
        return nullptr;
    }
    return &*it;
}

const std::vector<WorkPlane>& Document::workPlanes() const { return workPlanes_; }

void Document::addFeature(Feature feature) { features_.push_back(std::move(feature)); }

const std::vector<Object>& Document::objects() const { return objects_; }

const std::vector<Feature>& Document::features() const { return features_; }

} // namespace cadnext
