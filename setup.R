# setup.R — Installation des packages nécessaires
# À exécuter une seule fois avant de lancer l'application

packages <- c(
  "shiny",       # Framework application
  "bslib",       # UI moderne (Bootstrap 5)
  "leaflet",     # Carte interactive
  "sf",          # Données spatiales
  "duckdb",      # Lecture efficace de fichiers Parquet distants
  "DBI",         # Interface DuckDB
  "dplyr",       # Manipulation de données
  "tidyr",       # Reshape
  "lubridate",   # Gestion des dates
  "readr",       # Lecture CSV
  "jsonlite",    # Parsing GeoJSON
  "httr2",       # Requêtes HTTP (API Geo)
  "scales",      # Palettes de couleurs
  "glue",        # Interpolation de chaînes
  "DT"           # Tableaux interactifs
)

to_install <- packages[!packages %in% installed.packages()[, "Package"]]
if (length(to_install) > 0) {
  install.packages(to_install)
}

remotes::install_github("trafficonese/leaflet.extras")

cat("Tous les packages sont installés.\n")
