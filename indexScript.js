import { neon } from "https://cdn.jsdelivr.net/npm/@neondatabase/serverless@1/+esm";

// 1. Datenbankverbindung
const db_url = "postgresql://student:woshooyaefohshe0eegh8uSh5sa5pi3y@ep-cool-star-a2r1snwf.eu-central-1.aws.neon.tech/dbis2?sslmode=require";
const sql = neon(db_url);

// 2. Karte definieren
const center = L.latLng(47.660496, 9.171743);
const southWest = L.latLng(47.595496, 9.091743);
const northEast = L.latLng(47.720496, 9.251743);
const bounds = L.latLngBounds(southWest, northEast);

const map = L.map('map', {
    maxBounds: bounds,
    maxBoundsViscosity: 1.0,
    zoomControl: false
}).setView(center, 14);

L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);

// 3. Bus-Haltestellen laden
async function ladeHaltestellen() {
    const rows = await sql`
        SELECT ST_AsGeoJSON(ST_Transform(way, 4326)) AS geojson
        FROM osm.planet_osm_point
        WHERE (
                    highway = 'bus_stop'
                OR amenity = 'bus_station'
                OR tags -> 'highway' = 'bus_stop'
                OR tags -> 'amenity' = 'bus_station'
            )
          AND ST_DWithin(
                ST_Transform(way, 4326)::geography,
                ST_SetSRID(ST_MakePoint(${9.171392}, ${47.664316}), 4326)::geography,
                ${1000}
              );
    `;

    console.log("Antwort von DB:", rows.length, "Einträge");
    console.log(rows);

    rows.forEach(row => {
        const gj = row.geojson ?? Object.values(row)[0];
        console.log("GeoJSON:", gj);
        L.geoJSON(JSON.parse(gj)).addTo(map);
    });
}

// 4. Testverbindung & Button-Event
console.log(await sql`SELECT 1 + 1`);
document.getElementById('btn-load').addEventListener('click', ladeHaltestellen);