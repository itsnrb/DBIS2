
DROP TABLE IF EXISTS kn_geojson_cache;
CREATE TABLE kn_geojson_cache (
                                  id INT PRIMARY KEY DEFAULT 1,  -- Nur ein Eintrag möglich
                                  created_at TIMESTAMPTZ DEFAULT NOW(),
                                  start             jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  dest              jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  start_busstop     jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  dest_busstop      jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  airline           jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  busroute_direct   jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  busroute_via      jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  start_footroute   jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  dest_footroute    jsonb DEFAULT '{"type":"FeatureCollection","features":[]}',
                                  route_busstops    jsonb DEFAULT '{"type":"FeatureCollection","features":[]}'
);
INSERT INTO kn_geojson_cache (id) VALUES (1)
ON CONFLICT DO NOTHING;

DROP TABLE IF EXISTS kn_busstop;
CREATE TABLE kn_busstop AS
SELECT
    p.osm_id,
    p.name,
    p.operator,
    hstore(p.tags) AS tags,
    ST_AsGeoJSON(ST_Transform(p.way, 4326))::jsonb AS position,
    ST_Transform(p.way, 4326) AS geom  -- ← GEOMETRY(Point, 4326)
FROM osm.planet_osm_point p
WHERE
    highway = 'bus_stop'
   OR amenity = 'bus_station'
   OR tags -> 'highway' = 'bus_stop'
   OR tags -> 'amenity' = 'bus_station';


DROP TABLE IF EXISTS public.kn_carways;

CREATE TABLE public.kn_carways AS
SELECT *,
       length_m / (LEAST(40, maxspeed_forward) / 3.6) AS cost_t
FROM routing.konstanzcar_ways;

CREATE TABLE public.kn_pedways AS
SELECT *,
       length_m / (LEAST(4.5, maxspeed_forward) / 3.6) AS cost_t
FROM routing.konstanzped_ways;


CREATE OR REPLACE FUNCTION kn_delete_geojson_cache() RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache
    SET
        start             = '{"type":"FeatureCollection","features":[]}'::jsonb,
        dest              = '{"type":"FeatureCollection","features":[]}'::jsonb,
        start_busstop     = '{"type":"FeatureCollection","features":[]}'::jsonb,
        dest_busstop      = '{"type":"FeatureCollection","features":[]}'::jsonb,
        airline           = '{"type":"FeatureCollection","features":[]}'::jsonb,
        busroute_direct   = '{"type":"FeatureCollection","features":[]}'::jsonb,
        busroute_via      = '{"type":"FeatureCollection","features":[]}'::jsonb,
        start_footroute   = '{"type":"FeatureCollection","features":[]}'::jsonb,
        dest_footroute    = '{"type":"FeatureCollection","features":[]}'::jsonb,
        created_at        = NOW()
    WHERE id = 1;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION kn_cache_nearby_busstop(p_type TEXT) RETURNS VOID AS $$
DECLARE
    p JSONB;
    pt GEOMETRY;
    nearest RECORD;
    geojson JSONB;
BEGIN
    -- 1. Hole die gespeicherte Koordinate vom Typ (start oder dest)
    IF p_type = 'start' THEN
        SELECT start INTO p FROM kn_geojson_cache WHERE id = 1;
    ELSIF p_type = 'dest' THEN
        SELECT dest INTO p FROM kn_geojson_cache WHERE id = 1;
    ELSE
    END IF;

    -- 2. Extrahiere lng und lat für die Punktgeometrie
    pt := ST_SetSRID(ST_MakePoint(
                             (p->>'lng')::DOUBLE PRECISION,
                             (p->>'lat')::DOUBLE PRECISION
                     ), 4326);

    -- 3. Suche nächste Haltestelle
    SELECT
        osm_id, name, operator,
        (position->>'coordinates')::JSONB AS coords
    INTO nearest
    FROM kn_busstop
    ORDER BY ST_Distance(kn_busstop.geom, pt)
    LIMIT 1;

-- 4. Extrahiere lng/lat aus Koordinate
    geojson := jsonb_build_object(
            'type', 'Feature',
            'geometry', jsonb_build_object(
                    'type', 'Point',
                    'coordinates', nearest.coords
                        ),
            'lat', nearest.coords->>1,
            'lng', nearest.coords->>0,
            'properties', jsonb_build_object(
                    'osm_id', nearest.osm_id,
                    'name', nearest.name,
                    'operator', nearest.operator
                          )
               );

    -- 5. Cache aktualisieren
    IF p_type = 'start' THEN
        UPDATE kn_geojson_cache SET start_busstop = geojson WHERE id = 1;
    ELSE
        UPDATE kn_geojson_cache SET dest_busstop = geojson WHERE id = 1;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_cache_airline() RETURNS VOID AS $$
DECLARE
    a JSONB;
    b JSONB;
    geom GEOMETRY;
    length_m DOUBLE PRECISION;
    geojson JSONB;
BEGIN
    SELECT start_busstop INTO a FROM kn_geojson_cache WHERE id = 1;
    SELECT dest_busstop INTO b FROM kn_geojson_cache WHERE id = 1;

    IF a IS NULL OR b IS NULL THEN
        RETURN;
    END IF;

    RAISE NOTICE 'Start: lat=% lng=% | Ziel: lat=% lng=%',
        a->>'lat', a->>'lng', b->>'lat', b->>'lng';

    -- Linie erzeugen
    geom := ST_SetSRID(ST_MakeLine(
                               ST_MakePoint((a->>'lng')::DOUBLE PRECISION, (a->>'lat')::DOUBLE PRECISION),
                               ST_MakePoint((b->>'lng')::DOUBLE PRECISION, (b->>'lat')::DOUBLE PRECISION)
                       ), 4326);

    -- Länge berechnen (in Metern)
    length_m := ST_DistanceSphere(
            ST_MakePoint((a->>'lng')::DOUBLE PRECISION, (a->>'lat')::DOUBLE PRECISION),
            ST_MakePoint((b->>'lng')::DOUBLE PRECISION, (b->>'lat')::DOUBLE PRECISION)
                );

    -- GeoJSON mit Länge einbauen
    geojson := jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(geom)::jsonb,
            'properties', jsonb_build_object(
                    'type', 'airline',
                    'note', 'Direkte Verbindung zwischen Start und Ziel',
                    'length_m', length_m
                          )
               );

    UPDATE kn_geojson_cache SET airline = geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;



SELECT kn_cache_airline();


CREATE OR REPLACE FUNCTION kn_cache_busroute_direct() RETURNS VOID AS $$
DECLARE
    a JSONB;
    b JSONB;
    start_id INT;
    end_id INT;
    total_length DOUBLE PRECISION;
    total_cost DOUBLE PRECISION;
    geom GEOMETRY;
    geojson JSONB;
BEGIN
    -- 1. Start & Ziel laden
    SELECT start_busstop INTO a FROM kn_geojson_cache WHERE id = 1;
    SELECT dest_busstop  INTO b FROM kn_geojson_cache WHERE id = 1;

-- 2. Nächsten Knoten zu Startpunkt finden
    SELECT id INTO start_id
    FROM routing.konstanzcar_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(
            ST_MakePoint((a->>'lng')::DOUBLE PRECISION, (a->>'lat')::DOUBLE PRECISION), 4326)
    LIMIT 1;

-- 3. Nächsten Knoten zu Zielpunkt finden
    SELECT id INTO end_id
    FROM routing.konstanzcar_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(
            ST_MakePoint((b->>'lng')::DOUBLE PRECISION, (b->>'lat')::DOUBLE PRECISION), 4326)
    LIMIT 1;


-- 4. Route berechnen
    SELECT
        ST_SetSRID(ST_LineMerge(ST_Collect(e.the_geom)), 4326),
        SUM(e.length_m),
        SUM(e.cost_t)
    INTO geom, total_length, total_cost
    FROM pgr_dijkstra(
                 'SELECT gid AS id, source, target, cost, reverse_cost FROM kn_carways',
                 start_id, end_id, directed := true
         ) r
             JOIN kn_carways e ON r.edge = e.gid;


    geojson := jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(geom)::jsonb,
            'properties', jsonb_build_object(
                    'type', 'busroute_direct',
                    'note', 'Kürzeste Route entlang Straßen',
                    'length_m', total_length,
                    'duration_s', total_cost
                          )
               );


    UPDATE kn_geojson_cache SET busroute_direct = geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_cache_footroute(p_type TEXT) RETURNS VOID AS $$
DECLARE
    start_geom JSONB;
    dest_geom  JSONB;
    start_id   INT;
    end_id     INT;
    geom       GEOMETRY;
    total_length DOUBLE PRECISION;
    total_cost   DOUBLE PRECISION;
    geojson      JSONB;
BEGIN
    -- 1. Abhängig vom Typ die Start- und Zielpunkte wählen
    IF p_type = 'start' THEN
        SELECT start, start_busstop INTO start_geom, dest_geom FROM kn_geojson_cache WHERE id = 1;
    ELSIF p_type = 'dest' THEN
        SELECT dest, dest_busstop INTO start_geom, dest_geom FROM kn_geojson_cache WHERE id = 1;
    ELSE
        RAISE EXCEPTION 'Ungültiger Typ: %, erlaubt sind "start" oder "dest"', p_type;
    END IF;

    -- 2. Nächste Routingknoten bestimmen
    SELECT id INTO start_id
    FROM routing.konstanzped_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint((start_geom->>'lng')::DOUBLE PRECISION, (start_geom->>'lat')::DOUBLE PRECISION), 4326)
    LIMIT 1;

    SELECT id INTO end_id
    FROM routing.konstanzped_ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint((dest_geom->>'lng')::DOUBLE PRECISION, (dest_geom->>'lat')::DOUBLE PRECISION), 4326)
    LIMIT 1;

    IF start_id = end_id THEN
        RETURN;
    END IF;

    -- 3. Dijkstra-Routing Fußweg
    SELECT
        ST_SetSRID(ST_LineMerge(ST_Collect(w.the_geom)), 4326),
        SUM(w.length_m),
        SUM(w.cost_t)
    INTO geom, total_length, total_cost
    FROM pgr_dijkstra(
                 'SELECT gid AS id, source, target, cost, reverse_cost FROM kn_pedways',
                 start_id, end_id, directed := true
         ) r
             JOIN kn_pedways w ON r.edge = w.gid;

    IF geom IS NULL THEN
        RETURN;
    END IF;

    -- 4. GeoJSON erzeugen
    geojson := jsonb_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(geom)::jsonb,
            'properties', jsonb_build_object(
                    'type', 'footroute_' || p_type,
                    'note', 'Kürzeste Fußverbindung ' || p_type,
                    'length_m', total_length,
                    'duration_s', total_cost
                          )
               );

    -- 5. In Cache speichern
    IF p_type = 'start' THEN
        UPDATE kn_geojson_cache SET start_footroute = geojson WHERE id = 1;
    ELSE
        UPDATE kn_geojson_cache SET dest_footroute = geojson WHERE id = 1;
    END IF;

END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS kn_update_cache_route_busstops();
CREATE OR REPLACE FUNCTION kn_update_cache_route_busstops() RETURNS VOID AS $$
DECLARE
    route_geom GEOMETRY;
    buffer_geom GEOMETRY;
    geojson JSONB;
BEGIN
    SELECT ST_SetSRID(ST_GeomFromGeoJSON(busroute_direct->>'geometry'), 4326)
    INTO route_geom
    FROM kn_geojson_cache
    WHERE id = 1;


    buffer_geom := ST_Buffer(route_geom::geography, 100)::geometry;

    WITH matched AS (
        SELECT name, geom
        FROM kn_busstop
        WHERE ST_Intersects(geom, buffer_geom)
    ),
         features AS (
             SELECT jsonb_build_object(
                            'type', 'Feature',
                            'geometry', ST_AsGeoJSON(geom)::jsonb,
                            'properties', jsonb_build_object('name', name)
                    ) AS feature
             FROM matched
         )
    SELECT jsonb_build_object(
                   'type', 'FeatureCollection',
                   'features', COALESCE(jsonb_agg(feature), '[]'::jsonb)
           )
    INTO geojson
    FROM features;

    UPDATE kn_geojson_cache
    SET route_busstops = geojson
    WHERE id = 1;

END;
$$ LANGUAGE plpgsql;

SELECT kn_update_cache_route_busstops();


CREATE OR REPLACE FUNCTION kn_setposition(
    p_type TEXT,
    p_lat  DOUBLE PRECISION,
    p_lng  DOUBLE PRECISION
) RETURNS VOID AS $$
DECLARE
    geojson JSONB := jsonb_build_object(
            'type', 'Point',
            'coordinates', jsonb_build_array(p_lng, p_lat),
            'lat', p_lat,
            'lng', p_lng
                     );
BEGIN
    INSERT INTO kn_geojson_cache (id) VALUES (1)
    ON CONFLICT (id) DO NOTHING;

    IF p_type = 'start' THEN
        UPDATE kn_geojson_cache SET start = geojson WHERE id = 1;
    ELSIF p_type = 'dest' THEN
        UPDATE kn_geojson_cache SET dest = geojson WHERE id = 1;
    ELSE
        RAISE EXCEPTION 'Ungültiger type-Wert: %, erlaubt sind nur "start" oder "dest"', p_type;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Test
SELECT kn_setposition('start', 90, 17);


CREATE OR REPLACE FUNCTION kn_set_start_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET start = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_dest_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET dest = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_start_busstop_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET start_busstop = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_dest_busstop_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET dest_busstop = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_airline_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET airline = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_busroute_direct_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET busroute_direct = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_busroute_via_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET busroute_via = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_start_footroute_geojson(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    UPDATE kn_geojson_cache SET start_footroute = p_geojson WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_set_route_busstops(p_geojson JSONB) RETURNS VOID AS $$
BEGIN
    INSERT INTO kn_geojson_cache (id) VALUES (1)
    ON CONFLICT (id) DO NOTHING;

    UPDATE kn_geojson_cache
    SET route_busstops = p_geojson
    WHERE id = 1;
END;
$$ LANGUAGE plpgsql;


--Getter
--gemeinsame kn_getFromCache verworfen unterschiedlieche json objekte (Behandlung)
CREATE OR REPLACE FUNCTION kn_getposition(p_type TEXT)
    RETURNS JSONB AS $$
DECLARE
    result JSONB;
BEGIN
    IF p_type = 'start' THEN
        SELECT start INTO result FROM kn_geojson_cache WHERE id = 1;

    ELSIF p_type = 'dest' THEN
        SELECT dest INTO result FROM kn_geojson_cache WHERE id = 1;

    ELSE
        RAISE EXCEPTION 'Ungültiger type-Wert: %, erlaubt sind nur "start" oder "dest"', p_type;
    END IF;

    RETURN result;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION kn_getBusstop(p_type TEXT)
    RETURNS JSONB AS $$
DECLARE
    result JSONB;
BEGIN
    IF p_type = 'start' THEN
        SELECT start_busstop INTO result FROM kn_geojson_cache WHERE id = 1;

    ELSIF p_type = 'dest' THEN
        SELECT dest_busstop INTO result FROM kn_geojson_cache WHERE id = 1;

    ELSE
        RAISE EXCEPTION 'Ungültiger type-Wert: %, erlaubt sind nur "start" oder "dest"', p_type;
    END IF;

    RETURN result;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION kn_get_start_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT start INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_dest_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT dest INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_start_busstop_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT start_busstop INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_dest_busstop_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT dest_busstop INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_airline_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT airline INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_busroute_direct_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT busroute_direct INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_busroute_via_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT busroute_via INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_start_footroute_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT start_footroute INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_dest_footroute_geojson() RETURNS JSONB AS $$
DECLARE result JSONB;
BEGIN SELECT dest_footroute INTO result FROM kn_geojson_cache WHERE id = 1; RETURN result; END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kn_get_route_busstops_geojson() RETURNS JSONB AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT route_busstops INTO result FROM kn_geojson_cache WHERE id = 1;
    RETURN result;
END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION kn_update_cache()
    RETURNS TRIGGER AS $$
BEGIN
    -- Startposition geändert → Start-bezogene Cachefunktionen ausführen
    IF NEW.start IS DISTINCT FROM OLD.start THEN
        RAISE NOTICE 'Trigger ausgelöst – Änderung an Position erkannt.';
        PERFORM kn_cache_nearby_busstop('start');
        -- PERFORM kn_lookup_nearest_busstop('start');
        -- PERFORM kn_estimate_direct_busroute('start');
    END IF;


    -- Zielposition geändert → Ziel-bezogene Cachefunktionen ausführen
    IF NEW.dest IS DISTINCT FROM OLD.dest THEN
        RAISE NOTICE 'Trigger ausgelöst – Änderung an Position erkannt.';
        PERFORM kn_cache_nearby_busstop('dest');
        -- PERFORM kn_lookup_nearest_busstop('dest');
        -- PERFORM kn_estimate_direct_busroute('dest');
    END IF;
    -- Start und Ziel gesetzt
    IF NEW.start_busstop IS NOT NULL AND NEW.dest_busstop IS NOT NULL THEN
        RAISE NOTICE 'Trigger ausgelöst – Änderung an Position erkannt.';
        PERFORM kn_cache_airline();
        PERFORM kn_cache_busroute_direct();
        PERFORM kn_cache_footroute('start');
        PERFORM kn_cache_footroute('dest');
        PERFORM kn_update_cache_route_busstops();
    END IF;

    -- Prüfen, ob sich route_busstops geändert hat
    IF NEW.route_busstops IS DISTINCT FROM OLD.route_busstops THEN
        PERFORM kn_update_cache_busroute_via();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

--Trigger
DROP TRIGGER IF EXISTS kn_trg_position_change ON kn_geojson_cache;

CREATE TRIGGER kn_trg_position_change
    AFTER UPDATE OF start, dest ON kn_geojson_cache
    FOR EACH ROW
    WHEN (
        (OLD.start IS DISTINCT FROM NEW.start) OR
        (OLD.dest IS DISTINCT FROM NEW.dest)
        )
EXECUTE FUNCTION kn_update_cache();

DROP TRIGGER IF EXISTS trg_airline_cache ON kn_geojson_cache;

CREATE TRIGGER trg_airline_cache
    AFTER UPDATE OF start_busstop, dest_busstop ON kn_geojson_cache
    FOR EACH ROW
    WHEN (
        OLD.start_busstop IS DISTINCT FROM NEW.start_busstop OR
        OLD.dest_busstop IS DISTINCT FROM NEW.dest_busstop
        )
EXECUTE FUNCTION kn_update_cache();
