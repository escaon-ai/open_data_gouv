# R/03_geometry.R
# Récupère les contours GeoJSON des 25 communes via l'API Geo (geo.api.gouv.fr).
# Cache le résultat dans data/cache/communes_geo.rds.

library(sf)
library(httr2)
library(jsonlite)
library(dplyr)
library(readr)

CACHE_GEO <- "data/cache/communes_geo.rds"

communes_ref <- read_csv("data/communes_ref.csv", show_col_types = FALSE,
                         col_types = cols(code_insee = col_character()))

# ---- Récupération d'un contour depuis l'API Geo -------------------------

fetch_commune_geojson <- function(code_insee) {
  # L'API Geo renvoie le contour (polygone) quand geometry=contour est précisé.
  # Sans ce paramètre, elle renvoie le centroïde (point).
  url <- paste0(
    "https://geo.api.gouv.fr/communes/", code_insee,
    "?fields=nom&geometry=contour&format=geojson"
  )

  tryCatch({
    resp <- request(url) |>
      req_timeout(30) |>
      req_perform()

    geojson_text <- resp_body_string(resp)
    g <- sf::st_read(geojson_text, quiet = TRUE)

    # Vérifier que la géométrie est bien un polygone
    geom_type <- as.character(sf::st_geometry_type(g))
    if (!all(geom_type %in% c("POLYGON", "MULTIPOLYGON"))) {
      warning(glue::glue(
        "Commune {code_insee} : géométrie de type {geom_type[1]} ignorée ",
        "(contour non disponible dans l'API Geo)"
      ))
      return(NULL)
    }

    g
  }, error = function(e) {
    warning(glue::glue("Impossible de récupérer {code_insee}: {e$message}"))
    NULL
  })
}

# ---- Chargement (avec cache) --------------------------------------------

load_geometries <- function(force_refresh = FALSE) {
  if (!force_refresh && file.exists(CACHE_GEO)) {
    message("Cache géométries trouvé, chargement...")
    return(readRDS(CACHE_GEO))
  }

  message("Récupération des contours via API Geo (geo.api.gouv.fr)...")
  geoms <- lapply(communes_ref$code_insee, function(code) {
    message("  Commune ", code, "...")
    g <- fetch_commune_geojson(code)
    if (!is.null(g)) {
      g$code_insee <- code
      g
    }
  })

  # Supprimer les NULL et assembler
  geoms <- Filter(Negate(is.null), geoms)
  # communes_ref contient aussi "nom" → on ne joint que "agglomeration"
  # pour éviter la collision de colonnes (nom.x / nom.y)
  communes_sf <- do.call(rbind, geoms) |>
    left_join(communes_ref |> dplyr::select(code_insee, agglomeration),
              by = "code_insee") |>
    sf::st_transform(4326)  # WGS84 pour Leaflet

  dir.create("data/cache", showWarnings = FALSE, recursive = TRUE)
  saveRDS(communes_sf, CACHE_GEO)
  message("Cache géométries sauvegardé : ", CACHE_GEO)
  communes_sf
}

# ---- Agrégation en polygones d'agglomération ----------------------------

#' Fusionne les communes en 2 polygones (CARENE / CAPAtlantique)
build_agglo_polygons <- function(communes_sf) {
  communes_sf |>
    group_by(agglomeration) |>
    summarise(
      # st_make_valid corrige les géométries imprécises avant l'union,
      # ce qui évite les micro-frontières internes visibles dans Leaflet
      geometry = sf::st_union(sf::st_make_valid(geometry)),
      .groups = "drop"
    ) |>
    sf::st_as_sf()
}
