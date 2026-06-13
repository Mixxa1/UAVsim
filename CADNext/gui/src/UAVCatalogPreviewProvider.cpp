#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"

namespace cadnext::gui {

namespace {

using T = UAVPreviewVehicleType;
using C = UAVPreviewMassCategory;

UAVMountPointPreview mp(const std::string& id, const std::string& name,
                        const std::string& role,
                        double px = 0.0, double py = 0.0, double pz = 0.0)
{
    UAVMountPointPreview m;
    m.id = id;
    m.name = name;
    m.role = role;
    m.localPosition = {px, py, pz};
    return m;
}

std::vector<UAVCatalogPreviewItem> buildCatalog()
{
    std::vector<UAVCatalogPreviewItem> items;
    items.reserve(15);

    // 1. DJI Matrice 350 RTK — enterprise quadcopter
    {
        UAVCatalogPreviewItem i;
        i.id = "dji-matrice-350-rtk";
        i.name = "DJI Matrice 350 RTK";
        i.country = "Китай";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::medium;
        i.emptyMassKg      = 6.47;   // 3.77 kg frame + 2.70 kg TB65 batteries
        i.maxPayloadMassKg = 2.73;   // MTOW − empty = 9.2 − 6.47
        i.maxTakeoffMassKg = 9.2;
        i.hasVerifiedData  = true;
        i.mountPoints = {
            mp("mp-1", "Нижний разъём полезной нагрузки", "payload",  0.0, -0.12, 0.0),
            mp("mp-2", "Верхний разъём полезной нагрузки", "payload",  0.0,  0.10, 0.0),
        };
        items.push_back(std::move(i));
    }

    // 2. DJI FlyCart 30 — heavy cargo
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
            mp("mp-1", "Грузовой отсек (основной)",       "payload",  0.00, -0.30, 0.00),
            mp("mp-2", "Грузовой отсек (дополнительный)", "payload",  0.15, -0.25, 0.00),
            mp("mp-3", "Общая точка крепления",            "generic",  0.00,  0.15, 0.00),
        };
        items.push_back(std::move(i));
    }

    // 3. DJI Mavic 4 Pro — consumer camera
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
            mp("mp-1", "Разъём камеры (нижний)", "sensor",  0.0, -0.04, 0.06),
        };
        items.push_back(std::move(i));
    }

    // 4. DJI Neo — nano
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
            mp("mp-1", "Нижняя камера", "sensor",  0.0, -0.015, 0.02),
        };
        items.push_back(std::move(i));
    }

    // 5. DJI Phantom 3 Standard
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
            mp("mp-1", "Разъём подвеса", "sensor",  0.0, -0.035, 0.05),
        };
        items.push_back(std::move(i));
    }

    // 6. Freefly Alta X — heavy cinema/industrial
    {
        UAVCatalogPreviewItem i;
        i.id = "freefly-alta-x";
        i.name = "Freefly Alta X";
        i.country = "США";
        i.vehicleType  = T::multicopter;
        i.massCategory = C::heavy;
        i.emptyMassKg      = 19.80;  // 10.86 frame + ~8.94 batteries
        i.maxPayloadMassKg = 15.06;
        i.maxTakeoffMassKg = 34.86;
        i.hasVerifiedData  = true;
        i.mountPoints = {
            mp("mp-1", "Нижний подвес",           "payload",  0.0, -0.20, 0.00),
            mp("mp-2", "Верхний подвес",           "payload",  0.0,  0.15, 0.00),
            mp("mp-3", "Общая точка крепления",    "generic",  0.0,  0.00, 0.00),
        };
        items.push_back(std::move(i));
    }

    // 7. Griff 30 — heavy cargo
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
            mp("mp-1", "Грузовой подвес",        "payload",  0.0, -0.35, 0.00),
            mp("mp-2", "Общая точка крепления",   "generic",  0.0,  0.00, 0.00),
        };
        items.push_back(std::move(i));
    }

    // 8. Griff 60 — extra-heavy cargo
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
            mp("mp-1", "Грузовой подвес (основной)", "payload",  0.00, -0.45, 0.00),
            mp("mp-2", "Грузовой подвес (запасной)", "payload",  0.25, -0.35, 0.00),
            mp("mp-3", "Общая точка крепления",       "generic",  0.00,  0.00, 0.00),
        };
        items.push_back(std::move(i));
    }

    // 9. Avidrone 490TL — cargo helicopter
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
            mp("mp-1", "Грузовой отсек",        "payload",  0.0, -0.25, 0.00),
            mp("mp-2", "Общая точка крепления",  "generic",  0.0,  0.00, 0.00),
        };
        items.push_back(std::move(i));
    }

    // 10. WingtraOne GEN II — survey VTOL
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
            mp("mp-1", "Сенсорный отсек", "sensor",  0.0, -0.05, 0.10),
        };
        items.push_back(std::move(i));
    }

    // 11. Quantum Systems Trinity Pro
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
            mp("mp-1", "Сенсорный отсек",        "sensor",   0.0, -0.06, 0.12),
            mp("mp-2", "Общая точка крепления",   "generic",  0.0,  0.00, 0.00),
        };
        items.push_back(std::move(i));
    }

    // 12. MQ-9B SkyGuardian — MALE fixed-wing
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
            mp("mp-1", "Центральная точка крепления", "payload",  0.00, -0.15,  0.00),
            mp("mp-2", "Точка крепления №2",          "payload",  0.60, -0.12,  0.00),
            mp("mp-3", "Точка крепления №3",          "payload", -0.60, -0.12,  0.00),
            mp("mp-4", "Общая точка крепления",        "generic",  0.00,  0.00,  0.00),
        };
        items.push_back(std::move(i));
    }

    // 13. Hermes 900 — MALE ISR
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
            mp("mp-1", "Основная точка крепления", "payload",  0.00, -0.12,  0.00),
            mp("mp-2", "Сенсорный отсек",           "sensor",   0.00, -0.08,  0.30),
            mp("mp-3", "Общая точка крепления",      "generic",  0.00,  0.00,  0.00),
        };
        items.push_back(std::move(i));
    }

    // 14. FT5 Łoś — tactical fixed-wing
    {
        UAVCatalogPreviewItem i;
        i.id = "ft5-los";
        i.name = "FT5 Łoś";  // UTF-8: FT5 Łoś
        i.country = "Польша";
        i.vehicleType  = T::fixedWing;
        i.massCategory = C::medium;
        i.emptyMassKg      = 90.0;   // 85 kg frame + ~5 kg batteries
        i.maxPayloadMassKg = 30.0;
        i.maxTakeoffMassKg = 120.0;
        i.hasVerifiedData  = false;
        i.mountPoints = {
            mp("mp-1", "Основная точка крепления", "payload",  0.0, -0.10, 0.00),
            mp("mp-2", "Сенсорный отсек",           "sensor",   0.0, -0.06, 0.15),
        };
        items.push_back(std::move(i));
    }

    // 15. FlyEye — light fixed-wing
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
            mp("mp-1", "Сенсорный отсек", "sensor",  0.0, -0.04, 0.10),
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
