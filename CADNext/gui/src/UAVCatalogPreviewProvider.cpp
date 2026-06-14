#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"

namespace cadnext::gui {

namespace {

using T = UAVPreviewVehicleType;
using C = UAVPreviewMassCategory;

// nx/ny/nz: mount normal (unit vector pointing away from UAV surface).
// Default (0,-1,0) = pointing down from bottom surface.
UAVMountPointPreview mp(const std::string& id, const std::string& name,
                        const std::string& role,
                        double px = 0.0, double py = 0.0, double pz = 0.0,
                        double nx = 0.0, double ny = -1.0, double nz = 0.0)
{
    UAVMountPointPreview m;
    m.id           = id;
    m.name         = name;
    m.role         = role;
    m.localPosition = {px, py, pz};
    m.mountNormal   = {nx, ny, nz};
    return m;
}

std::vector<UAVCatalogPreviewItem> buildCatalog()
{
    std::vector<UAVCatalogPreviewItem> items;
    items.reserve(15);

    // ── 1. DJI Matrice 350 RTK ────────────────────────────────────────────────
    // Model: body center y=0.02; undercarriage bottom ≈ y=-0.053; gimbal bay
    // center y=-0.08 z=0.03; landing leg crossbar y=-0.19.
    {
        UAVCatalogPreviewItem i;
        i.id = "dji-matrice-350-rtk";
        i.name = "DJI Matrice 350 RTK";
        i.country = "Китай";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::medium;
        i.emptyMassKg      = 6.47;
        i.maxPayloadMassKg = 2.73;
        i.maxTakeoffMassKg = 9.2;
        i.hasVerifiedData  = true;
        i.mountPoints = {
            // Below undercarriage, above landing legs: y≈-0.09
            mp("mp-1", "Нижний разъём полезной нагрузки",  "payload",  0.00, -0.09,  0.00),
            // Above battery box top (y≈0.11): top accessory port
            mp("mp-2", "Верхний разъём аксессуаров",       "payload",  0.00,  0.12,  0.00, 0.0, 1.0, 0.0),
        };
        items.push_back(std::move(i));
    }

    // ── 2. DJI FlyCart 30 ─────────────────────────────────────────────────────
    // Model: cargo box center y=-0.14, bottom y=-0.21; landing legs y=-0.34.
    {
        UAVCatalogPreviewItem i;
        i.id = "dji-flycart-30";
        i.name = "DJI FlyCart 30";
        i.country = "Китай";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 65.0;
        i.maxPayloadMassKg = 30.0;
        i.maxTakeoffMassKg = 95.0;
        i.hasVerifiedData  = true;
        i.mountPoints = {
            mp("mp-1", "Грузовой отсек (основной)",        "payload",  0.00, -0.24,  0.00),
            mp("mp-2", "Грузовой отсек (дополнительный)",  "payload",  0.15, -0.22,  0.00),
            mp("mp-3", "Верхняя точка крепления",          "generic",  0.00,  0.22,  0.00, 0.0, 1.0, 0.0),
        };
        items.push_back(std::move(i));
    }

    // ── 3. DJI Mavic 4 Pro ───────────────────────────────────────────────────
    // Model: gimbal sphere at y=-0.040 z=0.090.
    {
        UAVCatalogPreviewItem i;
        i.id = "dji-mavic-4-pro";
        i.name = "DJI Mavic 4 Pro";
        i.country = "Китай";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::micro;
        i.emptyMassKg      = 1.05;
        i.maxPayloadMassKg = 0.10;
        i.maxTakeoffMassKg = 1.15;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Разъём камеры (нижний)", "sensor",  0.0, -0.042,  0.090),
        };
        items.push_back(std::move(i));
    }

    // ── 4. DJI Neo ────────────────────────────────────────────────────────────
    // Model: body bottom y=-0.017; camera shroud center y=-0.016 z=0.050.
    {
        UAVCatalogPreviewItem i;
        i.id = "dji-neo";
        i.name = "DJI Neo";
        i.country = "Китай";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::nano;
        i.emptyMassKg      = 0.135;
        i.maxPayloadMassKg = 0.02;
        i.maxTakeoffMassKg = 0.155;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Нижняя камера", "sensor",  0.0, -0.020,  0.048),
        };
        items.push_back(std::move(i));
    }

    // ── 5. DJI Phantom 3 Standard ─────────────────────────────────────────────
    // Model: body sphere y=0.02 r=0.085 sy=0.48 → bottom y=-0.021.
    // Gimbal box center y=-0.080 z=0.075.
    {
        UAVCatalogPreviewItem i;
        i.id = "dji-phantom-3-standard";
        i.name = "DJI Phantom 3 Standard";
        i.country = "Китай";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::micro;
        i.emptyMassKg      = 1.20;
        i.maxPayloadMassKg = 0.15;
        i.maxTakeoffMassKg = 1.35;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Разъём подвеса", "sensor",  0.0, -0.082,  0.075),
        };
        items.push_back(std::move(i));
    }

    // ── 6. Freefly Alta X ─────────────────────────────────────────────────────
    // Model: center disc top y=0.055; carbon frame bottom y=-0.065;
    // lower accent plate bottom y=-0.150; landing legs y=-0.28.
    {
        UAVCatalogPreviewItem i;
        i.id = "freefly-alta-x";
        i.name = "Freefly Alta X";
        i.country = "США";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 19.80;
        i.maxPayloadMassKg = 15.06;
        i.maxTakeoffMassKg = 34.86;
        i.hasVerifiedData  = true;
        i.mountPoints = {
            mp("mp-1", "Нижний подвес",          "payload",  0.0, -0.16,  0.00),
            mp("mp-2", "Верхний подвес",          "payload",  0.0,  0.10,  0.00, 0.0, 1.0, 0.0),
            mp("mp-3", "Общая точка крепления",   "generic",  0.0, -0.05,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 7. Griff 30 ───────────────────────────────────────────────────────────
    // Model: carbon frame bottom y=-0.06; lower plate bottom y=-0.165;
    // landing leg crossbar y=-0.30.
    {
        UAVCatalogPreviewItem i;
        i.id = "griff-30";
        i.name = "Griff 30";
        i.country = "Норвегия";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 18.0;
        i.maxPayloadMassKg = 30.0;
        i.maxTakeoffMassKg = 48.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Грузовой подвес",       "payload",  0.0, -0.19,  0.00),
            mp("mp-2", "Общая точка крепления",  "generic",  0.0, -0.06,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 8. Griff 60 ───────────────────────────────────────────────────────────
    // Model: frame bottom y=-0.07; lower plate bottom y=-0.24;
    // landing leg crossbar y=-0.38.
    {
        UAVCatalogPreviewItem i;
        i.id = "griff-60";
        i.name = "Griff 60";
        i.country = "Норвегия";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 32.0;
        i.maxPayloadMassKg = 60.0;
        i.maxTakeoffMassKg = 92.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Грузовой подвес (основной)",  "payload",  0.00, -0.28,  0.00),
            mp("mp-2", "Грузовой подвес (боковой)",   "payload",  0.25, -0.25,  0.00),
            mp("mp-3", "Общая точка крепления",        "generic",  0.00, -0.09,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 9. Avidrone 490TL ─────────────────────────────────────────────────────
    // Model: fuselage bottom y=-0.08; cargo pod center y=-0.15 z=0.04,
    // bottom y=-0.20; landing leg crossbar y=-0.24.
    {
        UAVCatalogPreviewItem i;
        i.id = "avidrone-490tl";
        i.name = "Avidrone 490TL";
        i.country = "Канада";
        i.vehicleType  = T::helicopter;
        i.massCategory = C::medium;
        i.emptyMassKg      = 34.0;
        i.maxPayloadMassKg = 23.0;
        i.maxTakeoffMassKg = 57.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Грузовой отсек",       "payload",  0.0, -0.22,  0.04),
            mp("mp-2", "Общая точка крепления", "generic",  0.0, -0.02,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 10. WingtraOne GEN II ─────────────────────────────────────────────────
    // Model: hCyl fuselage r=0.036; sensor module 0.11×0.05×0.24
    // center y=-0.035 z=0.05, bottom y=-0.060.
    {
        UAVCatalogPreviewItem i;
        i.id = "wingtraone-gen-ii";
        i.name = "WingtraOne GEN II";
        i.country = "Швейцария";
        i.vehicleType  = T::hybridVTOL;
        i.massCategory = C::light;
        i.emptyMassKg      = 3.7;
        i.maxPayloadMassKg = 0.8;
        i.maxTakeoffMassKg = 4.5;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Сенсорный отсек", "sensor",  0.0, -0.062,  0.05),
        };
        items.push_back(std::move(i));
    }

    // ── 11. Quantum Systems Trinity Pro ───────────────────────────────────────
    // Model: hCyl r=0.050; nose pod 0.16×0.08×0.34 center y=-0.03 z=0.12,
    // bottom y=-0.070.
    {
        UAVCatalogPreviewItem i;
        i.id = "quantum-systems-trinity-pro";
        i.name = "Quantum Systems Trinity Pro";
        i.country = "Германия";
        i.vehicleType  = T::hybridVTOL;
        i.massCategory = C::light;
        i.emptyMassKg      = 4.75;
        i.maxPayloadMassKg = 1.0;
        i.maxTakeoffMassKg = 5.75;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Сенсорный отсек",       "sensor",   0.0, -0.072,  0.12),
            mp("mp-2", "Общая точка крепления",  "generic",  0.0,  0.00,   0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 12. MQ-9B SkyGuardian ─────────────────────────────────────────────────
    // Model: hCyl(0,0,0,1.52,0.060) → fuselage bottom y=-0.060;
    // wing: 2.80m span at y=0.032, thickness 0.022 → wing bottom y=0.021;
    // sensor sphere at y=-0.085 z=0.34 (protrudes below fuselage).
    {
        UAVCatalogPreviewItem i;
        i.id = "mq-9b-skyguardian";
        i.name = "MQ-9B SkyGuardian";
        i.country = "США";
        i.vehicleType  = T::fixedWing;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 3493.0;
        i.maxPayloadMassKg = 2177.0;
        i.maxTakeoffMassKg = 5670.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            // Under sensor sphere / forward fuselage
            mp("mp-1", "Нижний разъём (нос)",        "payload",  0.00, -0.088,  0.30),
            // Right wing bottom at mid-span (wing bottom y≈0.021)
            mp("mp-2", "Правый пилон (крыло)",        "payload",  0.60,  0.018,  0.00),
            // Left wing bottom at mid-span
            mp("mp-3", "Левый пилон (крыло)",         "payload", -0.60,  0.018,  0.00),
            // Under fuselage center
            mp("mp-4", "Нижний разъём (центр)",       "generic",  0.00, -0.065,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 13. Hermes 900 ────────────────────────────────────────────────────────
    // Model: hCyl(0,0,0,1.12,0.050) → fuselage bottom y=-0.050;
    // sensor sphere r=0.042 at y=-0.06 z=0.28 (protrudes below fuselage);
    // sensor box 0.12×0.05×0.08 at y=-0.07 z=0.06.
    {
        UAVCatalogPreviewItem i;
        i.id = "hermes-900";
        i.name = "Hermes 900";
        i.country = "Израиль";
        i.vehicleType  = T::fixedWing;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 830.0;
        i.maxPayloadMassKg = 350.0;
        i.maxTakeoffMassKg = 1180.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            // Under fuselage center
            mp("mp-1", "Основная точка крепления",  "payload",  0.00, -0.055,  0.00),
            // At sensor ball center
            mp("mp-2", "Сенсорный отсек",           "sensor",   0.00, -0.062,  0.28),
            mp("mp-3", "Общая точка крепления",      "generic",  0.00,  0.00,   0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 14. FT5 Łoś ──────────────────────────────────────────────────────────
    // Model: hCyl(0,0,0,0.86,0.045) → fuselage bottom y=-0.045;
    // nose sensor box 0.12×0.05×0.10 center y=-0.06 z=0.10, bottom y=-0.085.
    {
        UAVCatalogPreviewItem i;
        i.id = "ft5-los";
        i.name = "FT5 Łoś";
        i.country = "Польша";
        i.vehicleType  = T::fixedWing;
        i.massCategory = C::medium;
        i.emptyMassKg      = 90.0;
        i.maxPayloadMassKg = 30.0;
        i.maxTakeoffMassKg = 120.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Основная точка крепления",  "payload",  0.0, -0.050,  0.00),
            mp("mp-2", "Сенсорный отсек (нос)",     "sensor",   0.0, -0.085,  0.10),
        };
        items.push_back(std::move(i));
    }

    // ── 15. FlyEye ────────────────────────────────────────────────────────────
    // Model: hCyl(0,0,0,0.58,0.030) → fuselage bottom y=-0.030;
    // nose box 0.08×0.04×0.07 center y=-0.045 z=0.10, bottom y=-0.065.
    {
        UAVCatalogPreviewItem i;
        i.id = "flyeye";
        i.name = "FlyEye";
        i.country = "Польша";
        i.vehicleType  = T::fixedWing;
        i.massCategory = C::light;
        i.emptyMassKg      = 10.8;
        i.maxPayloadMassKg = 1.2;
        i.maxTakeoffMassKg = 12.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Сенсорный отсек", "sensor",  0.0, -0.050,  0.10),
        };
        items.push_back(std::move(i));
    }

    return items;
}

} // namespace

const std::vector<UAVCatalogPreviewItem>& UAVCatalogPreviewProvider::catalog()
{
    static const std::vector<UAVCatalogPreviewItem> kCatalog = buildCatalog();
    return kCatalog;
}

} // namespace cadnext::gui
