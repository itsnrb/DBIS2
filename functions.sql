-- Create Tabelle busstops
CREATE TABLE IF NOT EXISTS public.busstops (
                                               id SERIAL PRIMARY KEY,
                                               name TEXT,
                                               geojson TEXT,
                                               dist_m DOUBLE PRECISION
);

--Function für Werte in die Tabelle aus der Tabelle osm.planet_osm_point
CREATE OR REPLACE FUNCTION insert_nearby_busstops(lon DOUBLE PRECISION, lat DOUBLE PRECISION, radius_m INTEGER DEFAULT 5000)
    RETURNS VOID AS
$$
BEGIN
    INSERT INTO public.busstops (name, geojson, dist_m)
    SELECT
        name,
        ST_AsGeoJSON(ST_Transform(way, 4326)) AS geojson,
        ST_Distance(
                ST_Transform(way, 4326)::geography,
                ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
        ) AS dist_m
    FROM osm.planet_osm_point
    WHERE (
        highway = 'bus_stop'
            OR amenity = 'bus_station'
            OR tags -> 'highway' = 'bus_stop'
            OR tags -> 'amenity' = 'bus_station'
        )
      AND ST_DWithin(
            ST_Transform(way, 4326)::geography,
            ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
            radius_m
          );
END;
$$ LANGUAGE plpgsql;

-- eigentlichen Werte einfügen
SELECT insert_nearby_busstops(9.171392, 47.664316);


-- 1) Sicher­stellen, dass PostGIS geladen ist
--    (einmal pro DB – falls schon geschehen, Zeile einfach weglassen)
CREATE EXTENSION IF NOT EXISTS postgis;


-- 3) (Optional, aber dringend empfohlen)
--    GiST-Index für <->-Operator, damit K-NN-Suche flott bleibt
CREATE INDEX IF NOT EXISTS busstops_geojson_gist
    ON public.busstops
        USING GIST (ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326));


-- Function für die nächste Bushaltestelle
CREATE OR REPLACE FUNCTION nearest_busstops_for_pair(
    lon1 DOUBLE PRECISION,
    lat1 DOUBLE PRECISION,
    lon2 DOUBLE PRECISION,
    lat2 DOUBLE PRECISION
)
    RETURNS TABLE (
                      point_label TEXT,         -- "A" oder "B"
                      id          INTEGER,
                      name        TEXT,
                      geojson     TEXT,
                      dist_m      DOUBLE PRECISION
                  )
    LANGUAGE sql
    STABLE
AS $$
    -- UNION von zwei Abfragen: jeweils nächste Haltestelle pro Punkt
(
    SELECT
        'A' AS point_label,
        id,
        name,
        geojson,
        ST_Distance(
                ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)::geography,
                ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)::geography
        ) AS dist_m
    FROM public.busstops
    ORDER BY
        ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)
            <-> ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)
    LIMIT 1
)
UNION ALL
(
    SELECT
        'B' AS point_label,
        id,
        name,
        geojson,
        ST_Distance(
                ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)::geography,
                ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)::geography
        ) AS dist_m
    FROM public.busstops
    ORDER BY
        ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)
            <-> ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)
    LIMIT 1
);
$$;

-- Function für die Distanz
CREATE OR REPLACE FUNCTION dist_between_nearest_busstops(
    lon1 DOUBLE PRECISION, lat1 DOUBLE PRECISION,
    lon2 DOUBLE PRECISION, lat2 DOUBLE PRECISION
)
    RETURNS DOUBLE PRECISION
    LANGUAGE sql
    STABLE
AS $$
WITH
    -- Nächste Haltestelle zu Punkt A
    nearest_a AS (
        SELECT ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)::geography AS geom
        FROM public.busstops
        ORDER BY ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)
                     <-> ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)
        LIMIT 1
    ),
    -- Nächste Haltestelle zu Punkt B
    nearest_b AS (
        SELECT ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)::geography AS geom
        FROM public.busstops
        ORDER BY ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)
                     <-> ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)
        LIMIT 1
    )
-- Abstand zwischen beiden Haltestellen
SELECT ST_Distance(a.geom, b.geom)
FROM nearest_a a, nearest_b b;
$$;

CREATE OR REPLACE FUNCTION calculate_route_by_coords(
    lon1 DOUBLE PRECISION,
    lat1 DOUBLE PRECISION,
    lon2 DOUBLE PRECISION,
    lat2 DOUBLE PRECISION
)
    RETURNS TABLE (
                      seq INTEGER,
                      node BIGINT,
                      edge BIGINT,
                      cost DOUBLE PRECISION,
                      geom geometry(LineString, 4326),
                      total_length DOUBLE PRECISION,
                      total_cost DOUBLE PRECISION
                  ) AS
$$
DECLARE
    start_vid BIGINT;
    end_vid BIGINT;
BEGIN
    -- Nächstgelegener Startknoten
    SELECT id INTO start_vid
    FROM routing.konstanzcar_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)
    LIMIT 1;

    -- Nächstgelegener Zielknoten
    SELECT id INTO end_vid
    FROM routing.konstanzcar_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)
    LIMIT 1;

    RETURN QUERY
        WITH route AS (
            SELECT * FROM pgr_dijkstra(
                    'SELECT gid AS id, source, target, cost_s AS cost, cost_s AS reverse_cost FROM routing.konstanzcar_ways',
                    start_vid, end_vid, directed := true
                          )
        ),
             route_geom AS (
                 SELECT
                     r.seq,
                     r.node,
                     r.edge,
                     r.cost,
                     w.the_geom AS geom
                 FROM route r
                          JOIN routing.konstanzcar_ways w ON r.edge = w.gid
             )
        SELECT
            rg.seq,
            rg.node,
            rg.edge,
            rg.cost,
            rg.geom,
            (SELECT SUM(ST_Length(rg2.geom::geography)) FROM route_geom rg2) AS total_length,
            (SELECT SUM(rg2.cost) FROM route_geom rg2) AS total_cost  -- jetzt in Sekunden!
        FROM route_geom rg;
END;
$$ LANGUAGE plpgsql;
SELECT * FROM calculate_route_by_coords(9.175, 47.660, 9.185, 47.662);

CREATE OR REPLACE FUNCTION calculate_route_info_by_coords(
    lon1 DOUBLE PRECISION,
    lat1 DOUBLE PRECISION,
    lon2 DOUBLE PRECISION,
    lat2 DOUBLE PRECISION
)
    RETURNS TABLE (
                      total_length DOUBLE PRECISION,  -- Meter
                      total_cost DOUBLE PRECISION     -- Sekunden
                  ) AS
$$
DECLARE
    start_vid BIGINT;
    end_vid BIGINT;
BEGIN
    -- Bestimme Start- und Ziel-Knoten im Netzwerk
    SELECT id INTO start_vid
    FROM routing.konstanzcar_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)
    LIMIT 1;

    SELECT id INTO end_vid
    FROM routing.konstanzcar_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)
    LIMIT 1;

    -- Route berechnen und Metriken liefern
    RETURN QUERY
        SELECT
            SUM(ST_Length(w.the_geom::geography)) AS total_length,
            SUM(r.cost) AS total_cost
        FROM pgr_dijkstra(
                     'SELECT gid AS id, source, target, cost_s AS cost, cost_s AS reverse_cost FROM routing.konstanzcar_ways',
                     start_vid, end_vid, directed := true
             ) AS r
                 JOIN routing.konstanzcar_ways AS w ON r.edge = w.gid;

END;
$$ LANGUAGE plpgsql;

SELECT * FROM calculate_route_info_by_coords(9.175, 47.660, 9.185, 47.662);

CREATE OR REPLACE FUNCTION calculate_foot_route(
    lon1 DOUBLE PRECISION,
    lat1 DOUBLE PRECISION,
    lon2 DOUBLE PRECISION,
    lat2 DOUBLE PRECISION
)
    RETURNS TABLE (
                      geom geometry(LineString, 4326),
                      total_length DOUBLE PRECISION,
                      total_cost DOUBLE PRECISION
                  ) AS $$
DECLARE
    start_vid BIGINT;
    end_vid BIGINT;
BEGIN
    -- Nächster Knoten zu Startpunkt
    SELECT id INTO start_vid
    FROM routing.konstanzped_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon1, lat1), 4326)
    LIMIT 1;

    -- Nächster Knoten zu Zielpunkt
    SELECT id INTO end_vid
    FROM routing.konstanzped_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon2, lat2), 4326)
    LIMIT 1;

    RETURN QUERY
        SELECT
            ST_LineMerge(ST_Collect(w.the_geom)) AS geom,
            SUM(ST_Length(w.the_geom::geography)) AS total_length,
            SUM(r.cost) AS total_cost
        FROM pgr_dijkstra(
                     'SELECT gid AS id, source, target, cost_s AS cost, cost_s AS reverse_cost FROM routing.konstanzped_ways',
                     start_vid, end_vid, directed := true
             ) AS r
                 JOIN routing.konstanzped_ways AS w ON r.edge = w.gid
        WHERE r.edge > 0
        group by w.the_geom;

END;
$$ LANGUAGE plpgsql;

