-- Datei: functions.sql
CREATE OR REPLACE FUNCTION public.get_nearby_bus_stops (
    p_lon     DOUBLE PRECISION,
    p_lat     DOUBLE PRECISION,
    p_radius  INTEGER DEFAULT 1000
)
RETURNS TABLE (geojson TEXT)  -- nur das GeoJSON zurückgeben
LANGUAGE sql
STABLE
AS $$
  SELECT ST_AsGeoJSON(ST_Transform(way, 4326))
  FROM   osm.planet_osm_point
  WHERE (
           highway = 'bus_stop'
        OR amenity = 'bus_station'
        OR tags -> 'highway' = 'bus_stop'
        OR tags -> 'amenity' = 'bus_station'
        )
    AND ST_DWithin(
          ST_Transform(way, 4326)::geography,
          ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography,
          p_radius
        );
$$;