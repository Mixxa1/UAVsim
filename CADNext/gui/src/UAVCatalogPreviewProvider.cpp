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
    // Body: placed(0,0.02,0) size(0.22,0.07,0.16); front face z=0.08
    // Gimbal bay: placed(0,-0.08,0.03) size(0.12,0.07,0.10) → bottom y=-0.115
    // Lower arm: placed(0,-0.03,-0.01) size(0.17,0.045,0.14) → bottom y=-0.053
    // Accent top: placed(0,0.06,-0.01) size(0.15,0.10,0.10) → top y=0.11
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
            mp("mp-1", "Нижний разъём полезной нагрузки",  "payload",  0.00, -0.115,  0.03),
            mp("mp-2", "Верхний разъём аксессуаров",       "payload",  0.00,  0.12,   0.00, 0.0, 1.0, 0.0),
            // Same gimbal bay port accepting camera gimbals (no role mismatch warning)
            mp("mp-3", "Нижний подвес камеры",             "camera",   0.00, -0.115,  0.04),
            // Front face of body: forward-looking sensor/LiDAR port
            mp("mp-4", "Передний датчик",                  "sensor",   0.00, -0.090,  0.09, 0.0, 0.0, 1.0),
            mp("mp-5", "Общая точка крепления",            "generic",  0.00, -0.053,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 2. DJI FlyCart 30 ─────────────────────────────────────────────────────
    // Body: placed(0,0.04,0) size(0.46,0.16,0.32); front face z=0.16
    // Cargo arm: placed(0,-0.14,0) size(0.30,0.14,0.28) → bottom y=-0.21
    // Accent top: placed(0,0.14,-0.02) size(0.36,0.12,0.24) → top y=0.20
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
            mp("mp-1", "Грузовой отсек (основной)",        "payload",  0.00, -0.21,  0.00),
            mp("mp-2", "Грузовой отсек (дополнительный)",  "payload",  0.15, -0.21,  0.00),
            mp("mp-3", "Верхняя точка крепления",          "generic",  0.00,  0.22,  0.00, 0.0, 1.0, 0.0),
            // Forward collision-avoidance / inspection sensor
            mp("mp-4", "Передний сенсор",                  "sensor",   0.00, -0.040,  0.17, 0.0, 0.0, 1.0),
            // Camera aimed at cargo (delivery verification)
            mp("mp-5", "Нижняя камера",                    "camera",   0.00, -0.210,  0.06),
        };
        items.push_back(std::move(i));
    }

    // ── 3. DJI Mavic 4 Pro ───────────────────────────────────────────────────
    // Body: placed(0,0.012,0) size(0.19,0.050,0.12) → bottom y=-0.013
    // Accent rear: placed(0,-0.010,0.082) size(0.08,0.032,0.05) → bottom y=-0.026
    // Gimbal sphere: scaledSphere(0,-0.040,0.090, 0.026, 1,0.85,1.05)
    //   → bottom y = -0.040 - 0.026*0.85 = -0.062
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
            mp("mp-1", "Разъём камеры (нижний)", "sensor",  0.00, -0.042,  0.090),
            // Bottom of gimbal sphere: camera role
            mp("mp-2", "Подвес камеры",          "camera",  0.00, -0.062,  0.090),
            // Bottom-rear body: generic structural point
            mp("mp-3", "Общая точка",            "generic", 0.00, -0.026, -0.040),
        };
        items.push_back(std::move(i));
    }

    // ── 4. DJI Neo ────────────────────────────────────────────────────────────
    // Body: placed(0,0,0) size(0.11,0.034,0.085) → bottom y=-0.017; top y=0.017
    // Accent top: placed(0,0.022,-0.01) size(0.07,0.020,0.05) → top y=0.032
    // Camera shroud: placed(0,-0.016,0.050) size(0.055,0.022,0.038) → bottom y=-0.027
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
            mp("mp-1", "Нижняя камера",   "sensor",  0.00, -0.020,  0.048),
            // Bottom of camera shroud: camera role
            mp("mp-2", "Камера (фронт)",  "camera",  0.00, -0.027,  0.050),
            // Top of body: generic upward accessory
            mp("mp-3", "Общая точка",     "generic", 0.00,  0.033, -0.010, 0.0, 1.0, 0.0),
        };
        items.push_back(std::move(i));
    }

    // ── 5. DJI Phantom 3 Standard ─────────────────────────────────────────────
    // Body sphere: scaledSphere(0,0.02,0, 0.085, 1.05,0.48,1) → bottom y≈-0.021
    // Gimbal box: placed(0,-0.080,0.075) size(0.060,0.032,0.040) → bottom y=-0.096
    // Upper shell: placed(0,0.056,-0.015) size(0.12,0.032,0.09) → top y=0.072
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
            mp("mp-1", "Разъём подвеса",  "sensor",  0.00, -0.096,  0.075),
            // Same gimbal port: camera role
            mp("mp-2", "Камера подвеса",  "camera",  0.00, -0.096,  0.080),
            // Under body sphere: generic accessory point
            mp("mp-3", "Общая точка",     "generic", 0.00, -0.022,  0.000),
        };
        items.push_back(std::move(i));
    }

    // ── 6. Freefly Alta X ─────────────────────────────────────────────────────
    // Disc: placed(0,0.04,0) r=0.16, h=0.03
    // Carbon frame: placed(0,-0.01,0) size(0.18,0.11,0.18) → front z=0.09
    // Accent plate: placed(0,-0.13,0) size(0.22,0.04,0.22) → bottom y=-0.150
    // Landing crossbars at y=-0.28
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
            mp("mp-1", "Нижний подвес",          "payload",  0.00, -0.16,  0.00),
            mp("mp-2", "Верхний подвес",          "payload",  0.00,  0.10,  0.00, 0.0, 1.0, 0.0),
            mp("mp-3", "Общая точка крепления",   "generic",  0.00, -0.05,  0.00),
            // Under accent plate: cinema camera gimbal mount
            mp("mp-4", "Нижняя камера",           "camera",   0.00, -0.150, 0.00),
            // Front face of carbon frame: forward-looking sensor
            mp("mp-5", "Передний сенсор",         "sensor",   0.00, -0.010, 0.09, 0.0, 0.0, 1.0),
        };
        items.push_back(std::move(i));
    }

    // ── 7. Griff 30 ───────────────────────────────────────────────────────────
    // Carbon frame: placed(0,0,0) size(0.22,0.12,0.22) → front z=0.11; bottom y=-0.06
    // Lower plate: placed(0,-0.14,0) size(0.26,0.05,0.26) → bottom y=-0.165; front z=0.13
    // Landing crossbars at y=-0.30
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
            mp("mp-1", "Грузовой подвес",        "payload",  0.00, -0.190, 0.00),
            mp("mp-2", "Общая точка крепления",  "generic",  0.00, -0.060, 0.00),
            // Under lower plate: camera gimbal mount
            mp("mp-3", "Нижняя камера",          "camera",   0.00, -0.165, 0.00),
            // Front face of body: forward sensor
            mp("mp-4", "Передний сенсор",        "sensor",   0.00,  0.000, 0.12, 0.0, 0.0, 1.0),
        };
        items.push_back(std::move(i));
    }

    // ── 8. Griff 60 ───────────────────────────────────────────────────────────
    // Carbon frame: placed(0,0.02,0) size(0.30,0.18,0.30) → front z=0.15; bottom y=-0.07
    // Lower plate: placed(0,-0.20,0) size(0.34,0.08,0.34) → bottom y=-0.240; front z=0.17
    // Landing crossbars at y=-0.38
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
            mp("mp-1", "Грузовой подвес (основной)",  "payload",  0.00, -0.280, 0.00),
            mp("mp-2", "Грузовой подвес (боковой)",   "payload",  0.25, -0.250, 0.00),
            mp("mp-3", "Общая точка крепления",        "generic",  0.00, -0.090, 0.00),
            // Under lower plate: cinema/survey camera mount
            mp("mp-4", "Нижняя камера",                "camera",   0.00, -0.240, 0.00),
            // Front face of carbon frame: forward sensor
            mp("mp-5", "Передний сенсор",              "sensor",   0.00,  0.020, 0.16, 0.0, 0.0, 1.0),
        };
        items.push_back(std::move(i));
    }

    // ── 9. Avidrone 490TL ─────────────────────────────────────────────────────
    // Fuselage: placed(0,-0.02,0) size(0.20,0.12,0.92) → nose z=0.46; bottom y=-0.08
    // Cargo pod: placed(0,-0.15,0.04) size(0.18,0.10,0.28) → bottom y=-0.200
    // Landing crossbars at y=-0.24
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
            mp("mp-1", "Грузовой отсек",         "payload",  0.00, -0.200,  0.04),
            mp("mp-2", "Общая точка крепления",   "generic",  0.00, -0.020,  0.00),
            // Cargo pod accepting camera payloads
            mp("mp-3", "Нижняя камера",           "camera",   0.00, -0.200,  0.05),
            // Nose of fuselage: forward sensor
            mp("mp-4", "Носовой датчик",          "sensor",   0.00, -0.020,  0.47, 0.0, 0.0, 1.0),
        };
        items.push_back(std::move(i));
    }

    // ── 10. WingtraOne GEN II ─────────────────────────────────────────────────
    // hCyl fuselage: placed(0,0,0) r=0.036, len=0.78 → bottom y=-0.036
    // Sensor module: placed(0,-0.035,0.05) size(0.11,0.05,0.24) → bottom y=-0.060
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
            mp("mp-1", "Сенсорный отсек",          "sensor",  0.00, -0.062,  0.050),
            // Same module accepting cameras (RGB, multispectral)
            mp("mp-2", "Камера (сенсорный отсек)",  "camera",  0.00, -0.062,  0.055),
            // Bottom of fuselage: generic structural point
            mp("mp-3", "Общая точка крепления",     "generic", 0.00, -0.036,  0.000),
        };
        items.push_back(std::move(i));
    }

    // ── 11. Quantum Systems Trinity Pro ───────────────────────────────────────
    // hCyl fuselage: placed(0,0,0) r=0.050 → bottom y=-0.050
    // Nose pod: placed(0,-0.03,0.12) size(0.16,0.08,0.34) → bottom y=-0.070; front z=0.29
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
            mp("mp-1", "Сенсорный отсек",        "sensor",  0.00, -0.072,  0.12),
            mp("mp-2", "Общая точка крепления",   "generic", 0.00,  0.000,  0.00),
            // Nose pod camera mount (same bay, camera role)
            mp("mp-3", "Камера (носовой отсек)",  "camera",  0.00, -0.072,  0.12),
            // Near nose-tip: forward-pointing sensor port
            mp("mp-4", "Датчик (передний)",       "sensor",  0.00, -0.030,  0.30, 0.0, 0.0, 1.0),
        };
        items.push_back(std::move(i));
    }

    // ── 12. MQ-9B SkyGuardian ─────────────────────────────────────────────────
    // hCyl fuselage: r=0.060 → bottom y=-0.060
    // Wing: placed(0,0.032,0.02) size(2.80,0.022,0.28) → bottom y=0.021
    // Sensor sphere: scaledSphere(0,-0.085,0.34, 0.055, 1,0.92,1)
    //   → bottom y = -0.085 - 0.055*0.92 = -0.136
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
            mp("mp-1", "Нижний разъём (нос)",      "payload",  0.00, -0.088,  0.30),
            mp("mp-2", "Правый пилон (крыло)",      "payload",  0.60,  0.018,  0.00),
            mp("mp-3", "Левый пилон (крыло)",       "payload", -0.60,  0.018,  0.00),
            mp("mp-4", "Нижний разъём (центр)",     "generic",  0.00, -0.065,  0.00),
            // Bottom of sensor ball: multi-spectral/SAR sensor
            mp("mp-5", "Нижний датчик (сфера)",     "sensor",   0.00, -0.136,  0.34),
            // EO/IR camera turret
            mp("mp-6", "Камера (турель)",            "camera",   0.00, -0.136,  0.35),
        };
        items.push_back(std::move(i));
    }

    // ── 13. Hermes 900 ────────────────────────────────────────────────────────
    // hCyl fuselage: r=0.050 → bottom y=-0.050
    // Sensor sphere: placed(0,-0.06,0.28) r=0.042 → bottom y=-0.102
    // Sensor box: placed(0,-0.07,0.06) size(0.12,0.05,0.08) → bottom y=-0.095
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
            mp("mp-1", "Основная точка крепления", "payload",  0.00, -0.055,  0.00),
            mp("mp-2", "Сенсорный отсек",          "sensor",   0.00, -0.062,  0.28),
            mp("mp-3", "Общая точка крепления",     "generic",  0.00,  0.000,  0.00),
            // Bottom of sensor sphere: EO/IR camera turret
            mp("mp-4", "Камера (нижняя сфера)",     "camera",   0.00, -0.102,  0.28),
        };
        items.push_back(std::move(i));
    }

    // ── 14. FT5 Łoś ──────────────────────────────────────────────────────────
    // hCyl fuselage: r=0.045 → bottom y=-0.045; nose cap z=0.43
    // Nose sensor box: placed(0,-0.06,0.10) size(0.12,0.05,0.10) → bottom y=-0.085
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
            mp("mp-1", "Основная точка крепления", "payload",  0.00, -0.050,  0.00),
            mp("mp-2", "Сенсорный отсек (нос)",    "sensor",   0.00, -0.085,  0.10),
            // Same nose bay accepting cameras
            mp("mp-3", "Камера (нос)",              "camera",   0.00, -0.085,  0.11),
            // Bottom of fuselage: generic attachment
            mp("mp-4", "Общая точка крепления",     "generic",  0.00, -0.045,  0.00),
        };
        items.push_back(std::move(i));
    }

    // ── 15. FlyEye ────────────────────────────────────────────────────────────
    // hCyl fuselage: r=0.030 → bottom y=-0.030; nose cap z=0.29
    // Nose box: placed(0,-0.045,0.10) size(0.08,0.04,0.07) → bottom y=-0.065
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
            mp("mp-1", "Сенсорный отсек",        "sensor",  0.00, -0.050,  0.10),
            // Nose box bottom: camera mount
            mp("mp-2", "Камера (нос)",            "camera",  0.00, -0.065,  0.10),
            // Bottom of fuselage: generic
            mp("mp-3", "Общая точка крепления",   "generic", 0.00, -0.030,  0.00),
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
