
CREATE TABLE IF NOT EXISTS public.busstops (
                                               id SERIAL PRIMARY KEY,
                                               name TEXT,
                                               geojson TEXT,
                                               dist_m DOUBLE PRECISION
);
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

SELECT insert_nearby_busstops(9.171392, 47.664316);


-- 1) Sicher­stellen, dass PostGIS geladen ist
--    (einmal pro DB – falls schon geschehen, Zeile einfach weglassen)
CREATE EXTENSION IF NOT EXISTS postgis;

-- 2) Funktion anlegen / erneuern
CREATE OR REPLACE FUNCTION nearest_busstop(
    lon DOUBLE PRECISION,   -- λ  (x)
    lat DOUBLE PRECISION    -- φ  (y)
)
    RETURNS TABLE (
                      id       INTEGER,
                      name     TEXT,
                      geojson  TEXT,
                      dist_m   DOUBLE PRECISION
                  )
    LANGUAGE sql
    STABLE                           -- liest nur, schreibt nichts
AS $$
SELECT
    id,
    name,
    geojson,
    ST_Distance(
            ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)::geography,
            ST_SetSRID(ST_MakePoint(lon,  lat),     4326)::geography
    ) AS dist_m
FROM public.busstops
ORDER BY
    ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326)
        <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)
LIMIT 1;
$$;

-- 3) (Optional, aber dringend empfohlen)
--    GiST-Index für <->-Operator, damit K-NN-Suche flott bleibt
CREATE INDEX IF NOT EXISTS busstops_geojson_gist
    ON public.busstops
        USING GIST (ST_SetSRID(ST_GeomFromGeoJSON(geojson), 4326));

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