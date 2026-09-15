#include "cadnext/fea/Material.hpp"

namespace cadnext::fea {

namespace {

constexpr double MPa = 1.0e6;
constexpr double GPa = 1.0e9;

const char* kMetalSource = "typical room-temperature values (ASM Handbook / supplier datasheets); not MMPDS allowables";

} // namespace

const std::vector<IsotropicMaterial>& materialLibrary() {
    static const std::vector<IsotropicMaterial> library = {
        {"al_6061_t6", "Алюминий 6061-T6", 2700.0, 68.9 * GPa, 0.33, 276.0 * MPa, 310.0 * MPa,
         false, kMetalSource, ""},
        {"al_7075_t6", "Алюминий 7075-T6", 2810.0, 71.7 * GPa, 0.33, 503.0 * MPa, 572.0 * MPa,
         false, kMetalSource, ""},
        {"ti_6al_4v", "Титан Ti-6Al-4V (отожжённый)", 4430.0, 113.8 * GPa, 0.342, 880.0 * MPa, 950.0 * MPa,
         false, kMetalSource, ""},
        {"steel_4130", "Сталь 4130 (нормализованная)", 7850.0, 205.0 * GPa, 0.29, 435.0 * MPa, 670.0 * MPa,
         false, kMetalSource, ""},
        {"cfrp_quasi_isotropic", "Углепластик, квазиизотропная укладка", 1550.0, 50.0 * GPa, 0.31,
         std::nullopt, 500.0 * MPa, true,
         "typical carbon/epoxy [0/±45/90]s laminate, Vf≈0.6, in-plane effective constants",
         "Compression-after-impact and interlaminar strength are lower and not modelled."},
        {"gfrp_quasi_isotropic", "Стеклопластик, квазиизотропная укладка", 1850.0, 18.0 * GPa, 0.30,
         std::nullopt, 250.0 * MPa, true,
         "typical E-glass/epoxy quasi-isotropic laminate, in-plane effective constants", ""},
        {"pla_fdm", "PLA, FDM-печать (в плоскости слоя)", 1240.0, 3.5 * GPa, 0.36,
         std::nullopt, 50.0 * MPa, true,
         "typical 100 % infill, loaded in the layer plane",
         "Across layers (Z) strength is roughly half; layer adhesion is not modelled."},
        {"petg_fdm", "PETG, FDM-печать (в плоскости слоя)", 1270.0, 2.0 * GPa, 0.38,
         std::nullopt, 45.0 * MPa, true,
         "typical 100 % infill, loaded in the layer plane",
         "Across layers (Z) strength is markedly lower; layer adhesion is not modelled."},
        {"abs_moulded", "ABS, литьё", 1050.0, 2.3 * GPa, 0.35, 40.0 * MPa, 43.0 * MPa,
         false, "typical injection-moulded ABS", "Creeps under sustained load; not modelled."},
        {"pa12_sls", "PA12, SLS-печать", 1010.0, 1.7 * GPa, 0.39,
         std::nullopt, 48.0 * MPa, true, "typical laser-sintered PA12", ""},
    };
    return library;
}

std::optional<IsotropicMaterial> findMaterial(const std::string& id) {
    const std::string resolved = (id == "default_abs") ? "abs_moulded" : id;
    for (const auto& material : materialLibrary()) {
        if (material.id == resolved) {
            return material;
        }
    }
    return std::nullopt;
}

} // namespace cadnext::fea
