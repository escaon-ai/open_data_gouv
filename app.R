# app.R — Carte interactive créations/clôtures d'entreprises
# Bassins d'emploi CARENE & CapAtlantique — données Sirene (INSEE / data.gouv.fr)

library(shiny)
library(bslib)
library(leaflet)
library(sf)
library(dplyr)
library(DT)

source("R/01_fetch_sirene.R")
source("R/02_process.R")
source("R/03_geometry.R")
source("R/04_map_helpers.R")

# ============================================================
# CHARGEMENT DES DONNÉES (une seule fois au démarrage)
# ============================================================

message("=== Chargement des données Sirene ===")
sirene    <- load_sirene_data()
data_agg  <- build_aggregated(sirene$stock, sirene$histo)

message("=== Chargement des géométries ===")
communes_sf <- load_geometries()
agglos_sf   <- build_agglo_polygons(communes_sf)


# ---- Référentiels globaux -----------------------------------------------

pal         <- make_palette()
a10_ref     <- readr::read_csv("data/a10_labels.csv", show_col_types = FALSE)
mois_labels <- c("Jan","Fév","Mar","Avr","Mai","Jun",
                 "Jul","Aoû","Sep","Oct","Nov","Déc")
month_choices <- setNames(as.character(1:12), mois_labels)

# ---- Plage disponible dans data_agg -------------------------------------

available_ym    <- sort(unique(data_agg$annee_mois))
available_years <- sort(unique(substr(available_ym, 1, 4)))
max_ym          <- max(available_ym)
max_year        <- substr(max_ym, 1, 4)
max_month       <- as.integer(substr(max_ym, 6, 7))

last_full_year <- if ("2025-12" %in% available_ym) {
  "2025"
} else {
  as.character(as.integer(max_year) - 1)
}

default_start_year  <- last_full_year
default_start_month <- "1"
default_end_year    <- last_full_year
default_end_month   <- "12"

# ============================================================
# UI
# ============================================================

ui <- page_sidebar(
  title = "Taux de renouvellement des établissements — agglomérations CARENE & CapAtlantique",
  theme = bs_theme(bootswatch = "flatly"),
  tags$head(tags$link(rel = "stylesheet", type = "text/css", href = "style.css")),

  sidebar = sidebar(
    width = 300,

    # ---- Secteurs ----
    h6("Secteurs d'activité (A10)"),
    checkboxGroupInput(
      "secteurs", label = NULL,
      choices  = setNames(a10_ref$code_a10, a10_ref$label),
      selected = a10_ref$code_a10
    ),
    actionButton("all_sectors",  "Tous",  class = "btn-sm btn-outline-secondary me-1"),
    actionButton("none_sectors", "Aucun", class = "btn-sm btn-outline-secondary"),

    hr(),

    # ---- Période ----
    h6("Période"),
    fluidRow(
      column(2, tags$p(class = "text-end mt-2 mb-0 pe-0", tags$small("De"))),
      column(5, selectInput("start_year",  NULL, choices = available_years,
                            selected = default_start_year,  width = "100%")),
      column(5, selectInput("start_month", NULL, choices = month_choices,
                            selected = default_start_month, width = "100%"))
    ),
    fluidRow(
      column(2, tags$p(class = "text-end mt-1 mb-0 pe-0", tags$small("À"))),
      column(5, selectInput("end_year",  NULL, choices = available_years,
                            selected = default_end_year,  width = "100%")),
      column(5, selectInput("end_month", NULL, choices = month_choices,
                            selected = default_end_month, width = "100%"))
    ),
    uiOutput("period_warning"),

    hr(class = "sidebar-hr-tight"),

    # ---- Regroupement ----
    h6("Regroupement"),
    radioButtons(
      "groupement", label = NULL,
      choices  = c("Communes (25)" = "communes", "Agglomérations (2)" = "agglomerations"),
      selected = "communes"
    ),

    hr(),

    tags$p(
      tags$small(
        tags$a("Source : Base Sirene — INSEE / data.gouv.fr",
               href   = "https://www.data.gouv.fr/datasets/5b7ffc618b4c4169d30727e0",
               target = "_blank")
      )
    ),
    tags$p(
      tags$small(class = "text-muted",
        "Données au niveau établissement (SIRET). Une entreprise multi-sites génère plusieurs événements."
      )
    )
  ),

  # ---- Contenu principal : carte (gauche) + tableau (droite) ----
  layout_columns(
    col_widths = c(7, 5),
    
    card(
      card_header(textOutput("map_title")),
      leafletOutput("map", height = "650px")
    ),
    
    card(
      card_header(uiOutput("detail_header")),
      # --- MODIFICATION ICI : Encapsulation du tableau ---
      div(class = "table-reduite", 
          DT::DTOutput("detail_table")
      )
    )
  )
)

# ============================================================
# SERVER
# ============================================================

server <- function(input, output, session) {

  # ---- Validation de période -----------------------------------------------

  observe({
    req(input$end_year)
    if (input$end_year == max_year) {
      valid_months <- month_choices[as.integer(month_choices) <= max_month]
      current_end_month <- isolate(input$end_month)
      new_selected <- if (current_end_month %in% names(valid_months)) {
        current_end_month
      } else {
        as.character(max_month)
      }
      updateSelectInput(session, "end_month",
                        choices  = valid_months,
                        selected = new_selected)
    } else {
      updateSelectInput(session, "end_month",
                        choices  = month_choices,
                        selected = isolate(input$end_month))
    }
  })

  start_ym <- reactive({
    sprintf("%s-%02d", input$start_year, as.integer(input$start_month))
  })
  end_ym <- reactive({
    sprintf("%s-%02d", input$end_year, as.integer(input$end_month))
  })

  period_valid <- reactive({ end_ym() >= start_ym() })

  output$period_warning <- renderUI({
    if (!period_valid()) {
      tags$p(class = "text-danger mt-1 mb-0",
             tags$small("La date de fin est antérieure au début."))
    }
  })

  # ---- Sélection secteurs -----------------------------------------------

  observeEvent(input$all_sectors,  {
    updateCheckboxGroupInput(session, "secteurs", selected = a10_ref$code_a10)
  })
  observeEvent(input$none_sectors, {
    updateCheckboxGroupInput(session, "secteurs", selected = character(0))
  })

  # ---- Titre carte -------------------------------------------------------

  output$map_title <- renderText({
    n_sect <- length(input$secteurs)
    glue::glue(
      "Taux de renouvellement — {start_ym()} → {end_ym()}",
      " — {n_sect} secteur(s)"
    )
  })

  # ---- Données agrégées réactives ----------------------------------------

  data_carte <- reactive({
    req(length(input$secteurs) > 0, period_valid())
    aggregate_for_map(
      data       = data_agg,
      secteurs   = input$secteurs,
      start_ym   = start_ym(),
      end_ym     = end_ym(),
      groupement = input$groupement
    )
  })

  data_secteurs_detail <- reactive({
    req(length(input$secteurs) > 0, period_valid())
    data_agg |>
      filter(annee_mois >= start_ym(), annee_mois <= end_ym(),
             code_a10 %in% input$secteurs) |>
      group_by(code_insee, agglomeration, code_a10, label_secteur) |>
      summarise(n_creations = sum(n_creations),
                n_clotures  = sum(n_clotures), .groups = "drop")
  })

  # ---- Carte Leaflet : initialisation ------------------------------------

  output$map <- renderLeaflet({
    leaflet(options = leafletOptions(zoomControl = TRUE)) |>
      addProviderTiles(providers$CartoDB.Positron) |>
      setView(lng = -2.280, lat = 47.370, zoom = 10.5)
  })

  # ---- Mise à jour de la carte (proxy) -----------------------------------

  observe({
    dc   <- data_carte()
    grp  <- input$groupement
    pal_ <- make_palette()

    tot_cre <- sum(dc$n_creations, na.rm = TRUE)
    tot_clo <- sum(dc$n_clotures,  na.rm = TRUE)

    proxy <- leafletProxy("map")
    proxy |> clearShapes() |> clearControls()

    det <- data_secteurs_detail()

    if (grp == "communes") {
      sf_data <- communes_sf |>
        left_join(
          dc |> dplyr::select(code_insee, n_creations, n_clotures, taux_val, label_taux),
          by = "code_insee"
        )

      popups <- unname(mapply(function(code, nom, agglo, n_cre, n_clo) {
        d <- det |> filter(code_insee == code)
        make_popup(nom, agglo,
                   dplyr::coalesce(n_cre, 0L), dplyr::coalesce(n_clo, 0L), d)
      },
      sf_data$code_insee, sf_data$nom, sf_data$agglomeration,
      sf_data$n_creations, sf_data$n_clotures,
      USE.NAMES = FALSE))

      labels      <- unname(paste0(sf_data$nom, " — ", sf_data$label_taux))
      layer_ids   <- unname(as.character(sf_data$code_insee))
      fill_colors <- unname(taux_to_color(pal_, sf_data$taux_val))

      proxy |> addPolygons(
        data        = sf_data,
        layerId     = layer_ids,
        fillColor   = fill_colors,
        fillOpacity = 0.75,
        color       = "#333333", weight = 1, opacity = 0.8,
        highlightOptions = highlightOptions(
          weight = 3, color = "#000", fillOpacity = 0.9, bringToFront = TRUE
        ),
        popup = popups,
        label = labels
      )

    } else {
      sf_data <- agglos_sf |>
        left_join(
          dc |> dplyr::select(agglomeration, n_creations, n_clotures, taux_val, label_taux),
          by = "agglomeration"
        )

      popups <- unname(mapply(function(agglo, n_cre, n_clo) {
        d <- det |>
          filter(agglomeration == agglo) |>
          group_by(code_a10, label_secteur) |>
          summarise(n_creations = sum(n_creations),
                    n_clotures  = sum(n_clotures), .groups = "drop")
        make_popup(agglo, agglo,
                   dplyr::coalesce(n_cre, 0L), dplyr::coalesce(n_clo, 0L), d)
      },
      sf_data$agglomeration, sf_data$n_creations, sf_data$n_clotures,
      USE.NAMES = FALSE))

      labels      <- unname(paste0(sf_data$agglomeration, " — ", sf_data$label_taux))
      layer_ids   <- unname(as.character(sf_data$agglomeration))
      fill_colors <- unname(taux_to_color(pal_, sf_data$taux_val))

      proxy |> addPolygons(
        data        = sf_data,
        layerId     = layer_ids,
        fillColor   = fill_colors,
        fillOpacity = 0.70,
        color       = "#111111", weight = 2, opacity = 0.9,
        highlightOptions = highlightOptions(
          weight = 4, color = "#000", fillOpacity = 0.85, bringToFront = TRUE
        ),
        popup = popups,
        label = labels
      )
    }

    # Légende couleurs
    taux_breaks   <- c(-1, -0.5, 0, 0.5, 1)
    scaled_breaks <- rescale_taux(taux_breaks)
    proxy |> addLegend(
      position = "bottomright",
      colors   = c(pal_(scaled_breaks), "#cccccc"),
      labels   = c("-1 (que des fermetures)", "-0,5", "0 (équilibre)", "+0,5", "+1 (que des ouvertures)", "Aucune donnée"),
      title    = HTML("Taux de<br>renouvellement"),
      opacity  = 0.8
    )

    solde <- tot_cre - tot_clo
    taux  <- if ((tot_cre + tot_clo) > 0) sprintf("%+.2f", (tot_cre - tot_clo) / (tot_cre + tot_clo)) else "—"
    stats_html <- sprintf(
      "<div class='leaflet-stats-control'><b>Total sélection</b><br>Créations : <b>%s</b><br>Clôtures : <b>%s</b><br>Solde : <b>%+d</b><br>Taux : <b>%s</b></div>",
      tot_cre, tot_clo, solde, taux
    )
    proxy |> addControl(
      html     = HTML(stats_html),
      position = "bottomright",
      layerId  = "stats_control"
    )
  })

  # ---- Clic sur une zone → tableau de détail ----------------------------

  selected_zone <- reactiveVal(NULL)

  observeEvent(input$map_shape_click, {
    click_id <- input$map_shape_click$id
    message("[CLICK] Zone cliquée : id = ", click_id)
    if (!is.null(selected_zone()) && selected_zone() == click_id) {
      selected_zone(NULL)
    } else {
      selected_zone(click_id)
    }
  })

  codes_zone <- reactive({
    zone_id <- selected_zone()
    req(!is.null(zone_id))
    if (input$groupement == "communes") {
      zone_id
    } else {
      communes_ref$code_insee[communes_ref$agglomeration == zone_id]
    }
  })

  zone_name <- reactive({
    zone_id <- selected_zone()
    req(!is.null(zone_id))
    if (input$groupement == "communes") {
      communes_ref$nom[communes_ref$code_insee == zone_id]
    } else {
      zone_id
    }
  })

  # ---- En-tête du tableau de détail -------------------------------------

  output$detail_header <- renderUI({
    zone_id <- selected_zone()
    if (is.null(zone_id)) {
      tags$span(class = "text-muted",
                "Détail — cliquez sur une zone de la carte")
    } else {
      tags$span(
        tags$b(paste("Détail :", zone_name())),
        tags$small(class = "text-muted ms-2",
                   paste0(start_ym(), " → ", end_ym())),
        downloadButton("download_csv", "CSV",
                       class = "btn-sm btn-outline-primary ms-3"),
        actionButton("close_detail", "✕",
                     class = "btn-sm btn-outline-secondary ms-2")
      )
    }
  })

  # ---- Données du tableau ------------------------------------------------

  detail_data <- reactive({
    zone_id <- selected_zone()
    if (is.null(zone_id)) return(NULL)
    message("[TABLE] Chargement détail pour zone : ", zone_id)
    df <- get_enterprise_detail(
      stock          = sirene$stock,
      histo          = sirene$histo,
      ul             = sirene$ul,
      codes_communes = codes_zone(),
      secteurs       = input$secteurs,
      start_ym       = start_ym(),
      end_ym         = end_ym()
    )
    message("[TABLE] ", nrow(df), " lignes")
    df
  })

  # ---- Tableau de détail -------------------------------------------------

  output$detail_table <- DT::renderDT({
    df <- detail_data()
    if (is.null(df)) {
      DT::datatable(
        data.frame(
          Entreprise = character(0), SIRET = character(0),
          Secteur    = character(0), Type  = character(0),
          Date       = character(0), Commune = character(0)
        ),
        options  = list(
          dom      = "t",
          language = list(emptyTable = "Cliquez sur une zone de la carte.")
        ),
        rownames = FALSE
      )
    } else {
      DT::datatable(
        df,
        class   = "detail-dt",
        options = list(
          pageLength = 12,
          scrollX    = TRUE,
          order      = list(list(4, "desc"), list(3, "asc")),
          language   = list(
            search     = "Rechercher :",
            lengthMenu = "Afficher _MENU_ lignes",
            info       = "Lignes _START_ à _END_ sur _TOTAL_",
            paginate   = list(previous = "Préc.", `next` = "Suiv."),
            emptyTable = "Aucune entreprise pour cette sélection."
          )
        ),
        rownames = FALSE,
        filter   = "top"
      )
    }
  })

  output$download_csv <- downloadHandler(
    filename = function() {
      zone <- gsub("[^a-zA-Z0-9_-]", "_", zone_name())
      sprintf("detail_%s_%s_%s.csv", zone, start_ym(), end_ym())
    },
    content = function(file) {
      df      <- detail_data()
      indices <- input$detail_table_rows_all
      if (!is.null(indices)) df <- df[indices, , drop = FALSE]
      readr::write_csv(df, file)
    }
  )

  observeEvent(input$close_detail, {
    selected_zone(NULL)
  })
}

# ============================================================
# LANCEMENT
# ============================================================

shinyApp(ui, server)
