import { neon } from "https://cdn.jsdelivr.net/npm/@neondatabase/serverless@1/+esm";

// 1. Datenbankverbindung
const db_url = "postgresql://student:woshooyaefohshe0eegh8uSh5sa5pi3y@ep-damp-snow-a2z5f2zp.eu-central-1.aws.neon.tech:5432/dbis2";
const sql = neon(db_url);


// 2. Karte definieren
var southWest = L.latLng(47.6, 9.0),	northEast = L.latLng(47.7, 9.3);
var bounds = L.latLngBounds(southWest, northEast);
const map = L.map('map', {maxBounds: bounds, maxBoundsViscosity: 1.0, zoomControl: false}).setView([47.7084, 9.1517], 13);
map.dragging.disable();
map.scrollWheelZoom.disable();


L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);

// Liefert die nächstgelegenen Bushaltestellen zu Punkt A und Punkt B
async function findeNaechsteHaltestelle() {
    console.log("findeNaechsteHaltestelle (2-Punkte-Variante) called");

    // 1) Haben wir überhaupt zwei Punkte?
    if (!koordinatenA || !koordinatenB) {
        alert("Bitte zuerst zwei Punkte auf der Karte wählen!");
        return;
    }

    const { lon: lon1, lat: lat1 } = koordinatenA; // Punkt A
    const { lon: lon2, lat: lat2 } = koordinatenB; // Punkt B

    // 2) Abfrage an die DB-Funktion
    let rows;
    try {
        rows = await sql`
            SELECT *
            FROM nearest_busstops_for_pair(
                ${lon1}, ${lat1},   -- Punkt A
                ${lon2}, ${lat2}    -- Punkt B
            );
        `;
    } catch (err) {
        console.error("Fehler bei nearest_busstops_for_pair:", err);
        alert("Abfragefehler – siehe Konsole.");
        return;
    }

    // 3) Prüfen, ob etwas zurückkam
    if (!rows.length) {
        alert("Keine Haltestellen gefunden.");
        return;
    }

    // 4) Gefundene Haltestellen visualisieren
    rows.forEach(({ point_label, name, geojson, dist_m }) => {
        const feature = JSON.parse(geojson);
        const farbe = point_label === "A" ? "#ff0000" : "#0000ff"; // Rot für A, Blau für B

        L.geoJSON(feature, {
            pointToLayer: (_, latlng) =>
                L.circleMarker(latlng, {
                    radius: 8,
                    color: farbe,
                    fillOpacity: 0.8
                })
        })
            .addTo(map)
            .bindPopup(
                `Nächste Haltestelle zu Punkt ${point_label}:<br>` +
                `${name || "Haltestelle"}<br>` +
                `Entfernung: ${Math.round(dist_m)} m`
            )
            .openPopup();
    });
}
let koordinatenA = null;
let koordinatenB = null;
let markerA = null;
let markerB = null;

// Karte: Klick-Event für zwei Punkte
map.on("click", function (e) {
    const { lat, lng } = e.latlng;

    if (!koordinatenA) {
        // Punkt A setzen
        koordinatenA = { lat, lon: lng };
        markerA = L.marker([lat, lng], { icon: L.divIcon({ className: 'custom-icon-a', html: 'A', iconSize: [24, 24] }) })
            .addTo(map)
            .bindPopup(`Punkt A<br>Lat: ${lat.toFixed(6)}<br>Lon: ${lng.toFixed(6)}`)
            .openPopup();

        console.log("Punkt A gesetzt:", koordinatenA);
    } else if (!koordinatenB) {
        // Punkt B setzen
        koordinatenB = { lat, lon: lng };
        markerB = L.marker([lat, lng], { icon: L.divIcon({ className: 'custom-icon-b', html: 'B', iconSize: [24, 24] }) })
            .addTo(map)
            .bindPopup(`Punkt B<br>Lat: ${lat.toFixed(6)}<br>Lon: ${lng.toFixed(6)}`)
            .openPopup();

        console.log("Punkt B gesetzt:", koordinatenB);
    } else {
        // Reset
        map.removeLayer(markerA);
        map.removeLayer(markerB);
        koordinatenA = null;
        koordinatenB = null;
        markerA = null;
        markerB = null;
        console.log("Beide Punkte zurückgesetzt. Bitte erneut klicken.");
        alert("Punkte wurden zurückgesetzt. Bitte erneut zwei Punkte setzen.");
    }
});

let busstoppLinie = null;  // Globale Referenz, damit wir sie beim nächsten Klick löschen können

async function zeigeBushaltestellenEntfernung() {
    if (!koordinatenA || !koordinatenB) {
        alert("Bitte zuerst zwei Punkte setzen!");
        return;
    }

    const { lon: lon1, lat: lat1 } = koordinatenA;
    const { lon: lon2, lat: lat2 } = koordinatenB;

    try {
        // Hole beide Haltestellen als GeoJSON + Distanz
        const rows = await sql`
            SELECT point_label, geojson
            FROM nearest_busstops_for_pair(${lon1}, ${lat1}, ${lon2}, ${lat2});
        `;

        if (rows.length !== 2) {
            document.getElementById("output").textContent =
                "Haltestellen konnten nicht bestimmt werden.";
            return;
        }

        // Marker-Koordinaten extrahieren
        const coords = rows.map(({ geojson }) => {
            const feature = JSON.parse(geojson);
            return feature.coordinates.reverse(); // GeoJSON → [lat, lon]
        });

        // Alte Linie entfernen (falls vorhanden)
        if (busstoppLinie) {
            map.removeLayer(busstoppLinie);
        }

        // Neue Linie zeichnen
        busstoppLinie = L.polyline(coords, {
            color: "#ff6600",
            weight: 3,
            dashArray: "6, 6"
        }).addTo(map);

        // Distanz abrufen (separat!)
        const [distRow] = await sql`
            SELECT dist_between_nearest_busstops(
                ${lon1}, ${lat1},
                ${lon2}, ${lat2}
            ) AS dist_m;
        `;

        const distMeter = Math.round(distRow.dist_m);
        document.getElementById("output").textContent =
            `Distanz zwischen den nächsten Haltestellen: ${distMeter} m`;

    } catch (err) {
        console.error("Fehler bei Haltestellenverbindung:", err);
        document.getElementById("output").textContent =
            "Fehler beim Zeichnen der Verbindung – siehe Konsole.";
    }
}

document
    .getElementById("btn-showStopDistance")
    .addEventListener("click", zeigeBushaltestellenEntfernung);
document.getElementById("btn-loadNextBusStop")
    .addEventListener("click", findeNaechsteHaltestelle);
console.log("LOG")