# Carte interactive — Créations & clôtures d'entreprises

Carte Shiny interactive visualisant le ratio créations/clôtures d'établissements
sur les bassins d'emploi **CARENE** et **CapAtlantique** (Loire-Atlantique / Morbihan),
par secteur d'activité (nomenclature A10 INSEE), sur les 5 dernières années complètes.

## Fonctionnalités

- **Filtrage par secteur** : 10 macro-secteurs INSEE (A10) — Agriculture, Industrie, Construction, Commerce/Transport/Hôtellerie, Finance, Immobilier, Services, Santé/Enseignement, etc.
- **Filtrage par période** : sélection année + mois de début et de fin (données disponibles depuis 2021, défaut : dernière année complète)
- **Regroupement** : vue par commune (25) ou par agglomération (2)
- **Colorisation** : ratio créations/clôtures — rouge (ratio ≤ 0,2) → jaune (ratio = 1) → vert (ratio ≥ 5)
- **Popups** : détail par commune avec tableau récapitulatif par secteur
- **Tableau de détail** : clic sur une zone → liste nominative des entreprises créées/clôturées (SIRET, secteur, date, commune)

## Données

| Source | Description | Lien |
|--------|-------------|------|
| Base Sirene (INSEE) | Créations et clôtures d'établissements | [data.gouv.fr](https://www.data.gouv.fr/datasets/base-sirene-des-entreprises-et-de-leurs-etablissements-siren-siret) |
| API Geo | Contours communaux | [geo.api.gouv.fr](https://geo.api.gouv.fr) |

**Périmètre géographique — 25 communes :**

| Agglomération | Communes |
|---|---|
| CARENE | Besné, Donges, La Chapelle-des-Marais, Montoir-de-Bretagne, Pornichet, Saint-André-des-Eaux, Saint-Joachim, Saint-Malo-de-Guersac, Saint-Nazaire, Trignac |
| CapAtlantique | Assérac, Batz-sur-Mer, Guérande, Herbignac, La Baule-Escoublac, La Turballe, Le Croisic, Le Pouliguen, Mesquer, Piriac-sur-Mer, Saint-Lyphard, Saint-Molf, Camoël, Férel, Pénestin |

> Les 3 communes de Morbihan (Camoël 56030, Férel 56058, Pénestin 56155) sont incluses dans CapAtlantique.

## Installation et lancement

### Pré-requis

- R ≥ 4.2
- Les packages sont gérés via [`renv`](https://rstudio.github.io/renv/)

### Étapes

```r
# 1. Restaurer l'environnement renv (gère aussi leaflet.extras via renv.lock)
renv::restore()

# Si leaflet.extras n'est pas dans votre renv.lock, l'installer manuellement :
# remotes::install_github("trafficonese/leaflet.extras")

# 2. Lancer l'application
shiny::runApp(".")
```

> **Première exécution** : le chargement initial télécharge et filtre les fichiers
> Sirene depuis data.gouv.fr (~3,8 Go au total via DuckDB HTTP avec predicate pushdown).
> Durée estimée : **15 à 25 minutes** selon la connexion.
> Les résultats sont mis en cache dans `data/cache/` pour les lancements suivants.
>
> **Invalidation du cache** : supprimer `data/cache/*.rds` si vous modifiez la liste
> des communes ou si vous avez besoin de mettre à jour les données.

## Structure du projet

```
.
├── app.R                     # Application Shiny (UI + serveur)
├── setup.R                   # Installation des packages
├── R/
│   ├── 01_fetch_sirene.R     # Téléchargement Sirene via DuckDB (HTTP parquet)
│   ├── 02_process.R          # Mapping NAF→A10, agrégation commune×secteur×mois
│   ├── 03_geometry.R         # Contours communes via API Geo
│   └── 04_map_helpers.R      # Palette couleurs, popups, agrégation réactive
├── data/
│   ├── communes_ref.csv      # 25 communes avec codes INSEE corrects
│   ├── a10_labels.csv        # Nomenclature A10
│   └── cache/                # (gitignorés) Données filtrées en cache RDS
├── www/style.css
└── renv.lock                 # Versions exactes des packages R
```

## Notes techniques

### Architecture de données

- **DuckDB** lit les fichiers Parquet Sirene en HTTP avec predicate pushdown sur `codeCommuneEtablissement`, réduisant ~2 Go à ~150k lignes sans tout télécharger.
- Les **clôtures** viennent de `StockEtablissementHistorique` : ligne avec `etatAdministratifEtablissement = 'F'` + `changementEtatAdministratifEtablissement = 'true'`, la date de fermeture étant `dateDebut`.
- Les **noms d'entreprises** sont résolus via `StockUniteLegale` (jointure SIREN) : enseigne > dénomination établissement > dénomination unité légale > prénom + nom (personnes physiques) > SIRET en dernier recours.
- Le **cache RDS** dans `data/cache/` (3 fichiers, ~5 Mo) évite de re-scanner les parquets distants à chaque démarrage. À supprimer si les communes ou les colonnes requêtées changent.

### DuckDB local vs HTTP

L'approche actuelle (DuckDB HTTP + cache RDS) est adaptée au cas d'usage :
- **Avantage** : pas de 2,8 Go à stocker localement, le cache RDS (~3 Mo) est suffisant
- **Cas où DuckDB local serait utile** : si vous vouliez interroger les données avec des filtres dynamiques différents (autre périmètre géographique, autre plage temporelle) sans re-télécharger — le parquet local permettrait des re-requêtes instantanées. Pour ce projet avec 25 communes fixes, le gain est marginal.

### Complétude des données (au 12 mars 2026)

La Base Sirene est publiée mensuellement (mise à jour ~1er du mois avec données du mois précédent) :
- **2021-01 → 2025-12** : données complètes (5 années complètes)
- **2026-01** : données disponibles mais avec un léger décalage de déclaration (~2-4 semaines)
- **2026-02** : données partielles possibles (déclarations en retard)
- **2026-03** : non disponible (mois en cours)

### Palette de couleurs

Échelle linéaire par morceaux centrée sur ratio = 1 :
- ratio ≤ 0,2 → rouge foncé
- ratio = 1 → jaune/neutre (équilibre)
- ratio ≥ 5 → vert foncé
