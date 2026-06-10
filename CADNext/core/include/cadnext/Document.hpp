#pragma once

#include <string>
#include <vector>

#include "cadnext/Object.hpp"
#include "cadnext/Feature.hpp"
#include "cadnext/Result.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/Units.hpp"

namespace cadnext {

class Document {
public:
    Document();

    const std::string& id() const;
    void setId(std::string id);
    const std::string& name() const;
    void setName(std::string name);

    UnitSystem unitSystem() const;
    void setUnitSystem(UnitSystem units);

    void addObject(Object object);
    bool removeObject(const std::string& id);
    Result<Object> objectById(const std::string& id) const;
    Object* mutableObjectById(const std::string& id);

    // Sketches are stored next to objects (not embedded in them); the
    // project tree shows bodies and sketches as separate groups.
    void addSketch(Sketch sketch);
    bool removeSketch(const std::string& id);
    Result<Sketch> sketchById(const std::string& id) const;
    Sketch* mutableSketchById(const std::string& id);
    const std::vector<Sketch>& sketches() const;

    void addFeature(Feature feature);
    const std::vector<Object>& objects() const;
    const std::vector<Feature>& features() const;

private:
    std::string id_;
    std::string name_;
    UnitSystem units_ = UnitSystem::Metric;
    std::vector<Object> objects_;
    std::vector<Sketch> sketches_;
    std::vector<Feature> features_;
};

} // namespace cadnext
