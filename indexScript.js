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

/* -----------------------------------------------------------
   Bushaltestellen laden – jetzt nur noch Funktions-Aufruf
----------------------------------------------------------- */
async function ladeHaltestellen() {
    const lon = 9.171392;
    const lat = 47.664316;
    const radius = 1000;

    const result = await sql.query(
        `SELECT * FROM public.get_nearby_bus_stops($1::double precision, $2::double precision, $3::integer);`,
        [lon, lat, radius]
    );

    console.log("Bushaltestellen:", result.rows.length);
    result.rows.forEach(r => {
        const geo = JSON.parse(r.geojson);
        L.geoJSON(geo, {
            pointToLayer: (_, ll) => L.circleMarker(ll, { radius: 6, color: "#0066ff" })
        }).addTo(map);
    });
}

document.getElementById("btn-load")
    .addEventListener("click", ladeHaltestellen);