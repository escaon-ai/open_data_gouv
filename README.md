# Carte interactive — Taux de renouvellement des établissements

[![Voir l'application](https://img.shields.io/badge/Shiny-Voir%20l'application-blue?logo=r&logoColor=white)](https://escaon.shinyapps.io/open_data_gouv/)

Carte interactive visualisant le **taux de renouvellement des établissements** sur les
bassins d'emploi des agglomérations **CARENE** et **CapAtlantique**, par secteur
d'activité (nomenclature A10 INSEE), sur les 5 dernières années complètes.

[![Aperçu de l'application](www/screenshot.png)](https://escaon.shinyapps.io/open_data_gouv/)

## Fonctionnalités

- **Filtrage par secteur** : 10 macro-secteurs INSEE (A10) — Agriculture, Industrie, Construction, Commerce/Transport/Hôtellerie, Finance, Immobilier, Services, Santé/Enseignement, etc.
- **Filtrage par période** : sélection année + mois de début et de fin (données disponibles depuis 2021, défaut : dernière année complète)
- **Regroupement** : vue par commune (25) ou par agglomération (2)
- **Colorisation** : taux de renouvellement `(C − F) / (C + F)` — rouge (-1, que des fermetures) → jaune (0, équilibre) → vert (+1, que des ouvertures)
- **Popups** : détail par commune avec tableau récapitulatif par secteur
- **Tableau de détail** : clic sur une zone → liste nominative des établissements créés/clôturés (SIRET, secteur, date, commune) avec export CSV

## Données

### Base Sirene — INSEE (via data.gouv.fr)

**Dataset :** [Base Sirene des entreprises et de leurs établissements (SIREN, SIRET)](https://www.data.gouv.fr/datasets/base-sirene-des-entreprises-et-de-leurs-etablissements-siren-siret/)
**Producteur :** Institut national de la statistique et des études économiques (INSEE)
**Licence :** [Licence Ouverte v2.0 (Etalab)](https://www.etalab.gouv.fr/wp-content/uploads/2017/04/ETALAB-Licence-Ouverte-v2.0.pdf)
**Fréquence de mise à jour :** mensuelle (publication ~1er du mois, données du mois précédent)

Trois fichiers Parquet sont utilisés, lus directement via DuckDB HTTP :

| Fichier | Resource ID | Taille | Rôle dans l'application |
|---------|-------------|--------|--------------------------|
| `StockEtablissement_utf8.parquet` | `a29c1297-1f92-4e2a-8f6b-8c902ce96c5f` | ~2 Go | **Créations** : chaque ligne est un établissement actif. La date de création `dateCreationEtablissement` détermine le mois de création. Fournit aussi `activitePrincipaleEtablissement` (code NAF) et les dénominations. Predicate pushdown actif sur `codeCommuneEtablissement`. |
| `StockEtablissementHistorique_utf8.parquet` | `2b3a0c79-f97b-46b8-ac02-8be6c1f01a8c` | ~803 Mo | **Clôtures** : chaque ligne est un changement d'état. Les clôtures sont isolées par le filtre `etatAdministratifEtablissement = 'F'` ET `changementEtatAdministratifEtablissement = 'true'`. La date de clôture est `dateDebut`. Filtré par liste de SIRETs des 25 communes. |
| `StockUniteLegale_utf8.parquet` | `350182c9-148a-46e0-8389-76c2ec1374a3` | ~651 Mo | **Noms d'entreprises** : jointure sur SIREN (`substr(siret, 1, 9)`) pour résoudre la dénomination — `denominationUniteLegale`, `denominationUsuelle1UniteLegale`, `nomUniteLegale`, `prenomUsuelUniteLegale` (personnes physiques). |

#### Construction des indicateurs

**Créations (mois M) :** établissements du `StockEtablissement` dont `substr(dateCreationEtablissement, 1, 7) == M` et `codeCommuneEtablissement` dans le périmètre des 25 communes.

**Clôtures (mois M) :** lignes du `StockEtablissementHistorique` avec `etatAdministratifEtablissement = 'F'`, `changementEtatAdministratifEtablissement = 'true'`, et `substr(dateDebut, 1, 7) == M`, croisées avec le `StockEtablissement` pour retrouver la commune et le secteur NAF de l'établissement.

**Taux de renouvellement :** `(C − F) / (C + F)` sur la période sélectionnée, où C = créations et F = fermetures. Compris entre -1 (que des fermetures) et +1 (que des ouvertures), avec 0 comme équilibre. NA si aucune activité (C = F = 0).

**Secteurs :** code NAF (`activitePrincipaleEtablissement`, format `XX.XXX`) agrégé en 10 macro-secteurs INSEE (nomenclature A10) par plage de codes sur les deux premiers chiffres.

#### Autres sources

| Source | Usage | Lien |
|--------|-------|------|
| API Geo (DINUM) | Contours GeoJSON des communes | [geo.api.gouv.fr](https://geo.api.gouv.fr) |

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
# 1. Restaurer l'environnement renv
renv::restore()

# 2. Lancer l'application
shiny::runApp(".")
```

> **Première exécution** : le chargement initial télécharge et filtre les fichiers
> Sirene depuis data.gouv.fr (~3,8 Go au total via DuckDB HTTP).
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
│   └── cache/                # Données filtrées en cache RDS (versionnées pour déploiement)
├── www/style.css
└── renv.lock                 # Versions exactes des packages R
```

## Notes techniques

### Architecture de données

- **DuckDB** lit les fichiers Parquet Sirene en HTTP. Pour `StockEtablissement`, le predicate pushdown sur `codeCommuneEtablissement` réduit ~2 Go à ~150k lignes. Pour `StockEtablissementHistorique`, le filtre porte sur la liste de SIRETs des 25 communes (le fichier n'a pas de colonne géographique).
- Les **clôtures** viennent de `StockEtablissementHistorique` : ligne avec `etatAdministratifEtablissement = 'F'` + `changementEtatAdministratifEtablissement = 'true'`, la date de fermeture étant `dateDebut`.
- Les **noms d'entreprises** sont résolus via `StockUniteLegale` (jointure SIREN) : enseigne > dénomination établissement > dénomination unité légale > prénom + nom (personnes physiques) > SIRET en dernier recours.
- Le **cache RDS** dans `data/cache/` (3 fichiers, ~5 Mo) est versionné dans git pour que le déploiement shinyapps.io ne nécessite pas de re-télécharger les parquets au démarrage.

### Palette de couleurs

Échelle linéaire continue sur le taux de renouvellement `(C − F) / (C + F)` :
- -1 → rouge foncé (que des fermetures)
- 0 → jaune/neutre (équilibre parfait)
- +1 → vert foncé (que des ouvertures)
- NA → gris (aucune activité)

### Limites et biais connus

- **Établissements, pas entreprises :** les données sont au niveau SIRET. Une entreprise multi-sites (chaîne, franchise, BTP) génère autant d'événements que d'établissements — le taux n'est pas biaisé mais peut être influencé par quelques acteurs avec de nombreux sites.
- **Clôtures multiples :** un établissement fermé, rouvert, puis refermé dans la période peut être compté deux fois comme clôture. Ce cas concerne principalement les auto-entrepreneurs et commerces saisonniers.
- **Date de création :** `dateCreationEtablissement` peut refléter une réactivation administrative plutôt qu'une création économique réelle. Limitation intrinsèque de la Base Sirene.
- **Code NAF au moment de la fermeture :** le secteur est issu du `StockEtablissementHistorique` quand disponible, ou du stock actuel en fallback — ce dernier peut différer du code en vigueur au moment de la fermeture.
