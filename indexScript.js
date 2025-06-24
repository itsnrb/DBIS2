import { neon } from "https://cdn.jsdelivr.net/npm/@neondatabase/serverless@1/+esm";

console.log("SCRIPT GELADEN");

// 1. Datenbankverbindung
const db_url = "postgresql://student:woshooyaefohshe0eegh8uSh5sa5pi3y@ep-damp-snow-a2z5f2zp.eu-central-1.aws.neon.tech:5432/dbis2";
const sql = neon(db_url);

// 2. Karte definieren
var southWest = L.latLng(47.6, 9.0),	northEast = L.latLng(47.7, 9.3);
var bounds = L.latLngBounds(southWest, northEast);
const map = L.map('map', {
    maxBounds: bounds,
    maxBoundsViscosity: 1.0,
    zoomControl: true // Zoom-Steuerung oben rechts
}).setView([47.7084, 9.1517], 13);

L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);

document.getElementById("zoom-in").addEventListener("click", () => {
    map.zoomIn();
});

document.getElementById("zoom-out").addEventListener("click", () => {
    map.zoomOut();
});

// Liefert die nächstgelegenen Bushaltestellen zu Punkt A und Punkt B

let haltestellenLayer = []; // speichert GeoJSON-Layer für Bushaltestellen
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
    // 4) Gefundene Haltestellen visualisieren
    rows.forEach(({ point_label, name, geojson, dist_m }) => {
        const feature = JSON.parse(geojson);
        const farbe = point_label === "A" ? "#ff0000" : "#0000ff"; // Rot für A, Blau für B

        const layer = L.geoJSON(feature, {
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

        // Speichern für späteres Entfernen
        haltestellenLayer.push(layer);
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


let currentRouteLayer = null;

async function zeichneRouteVonBushaltestellen() {
    if (!koordinatenA || !koordinatenB) {
        alert("Bitte zuerst zwei Punkte auf der Karte setzen.");
        return;
    }

    try {
        // 1. Hole die zwei nächstgelegenen Bushaltestellen zu den beiden Punkten
        const rows = await sql`
            SELECT point_label, geojson
            FROM nearest_busstops_for_pair(
                ${koordinatenA.lon}, ${koordinatenA.lat},
                ${koordinatenB.lon}, ${koordinatenB.lat}
            );
        `;

        if (rows.length !== 2) {
            alert("Konnte die nächsten Bushaltestellen nicht ermitteln.");
            return;
        }

        // Koordinaten der Haltestellen extrahieren
        const haltestellen = {};
        rows.forEach(({ point_label, geojson }) => {
            const feature = JSON.parse(geojson);
            const [lon, lat] = feature.coordinates;
            haltestellen[point_label] = { lat, lon };
        });

        const start = haltestellen["A"];
        const ziel = haltestellen["B"];

        // 2. Alte Route entfernen
        if (currentRouteLayer) {
            map.removeLayer(currentRouteLayer);
        }

        // 3. Nur die Geometrie der Route laden
        const result = await sql`
            SELECT ST_AsGeoJSON(ST_LineMerge(ST_Collect(geom)))::json AS route_geom
            FROM calculate_route_by_coords(${start.lon}, ${start.lat}, ${ziel.lon}, ${ziel.lat});
        `;

        const route = result[0];
        if (!route || !route.route_geom) {
            alert("Keine Route gefunden.");
            return;
        }

        // 4. Route auf der Karte anzeigen
        currentRouteLayer = L.geoJSON(route.route_geom, {
            style: {
                color: "blue",
                weight: 4
            }
        }).addTo(map);

    } catch (err) {
        console.error("Fehler beim Zeichnen der Route über Haltestellen:", err);
        alert("Fehler beim Laden der Bushaltestellen-Route.");
    }
}
async function berechneDistanzUndDauerZwischenHaltestellen() {
    if (!koordinatenA || !koordinatenB) {
        alert("Bitte zuerst zwei Punkte auf der Karte setzen.");
        return;
    }

    try {
        // 1. Nächste Bushaltestellen abrufen
        const rows = await sql`
            SELECT point_label, geojson
            FROM nearest_busstops_for_pair(
                ${koordinatenA.lon}, ${koordinatenA.lat},
                ${koordinatenB.lon}, ${koordinatenB.lat}
            );
        `;

        if (rows.length !== 2) {
            alert("Konnte die nächsten Bushaltestellen nicht ermitteln.");
            return;
        }

        // 2. Koordinaten extrahieren
        const haltestellen = {};
        rows.forEach(({ point_label, geojson }) => {
            const feature = JSON.parse(geojson);
            const [lon, lat] = feature.coordinates;
            haltestellen[point_label] = { lat, lon };
        });

        const start = haltestellen["A"];
        const ziel = haltestellen["B"];

        // 3. Abfrage nur der Distanz und Dauer
        const result = await sql`
            SELECT 
                SUM(total_length) AS total_length,
                SUM(total_cost) AS total_cost
            FROM calculate_route_by_coords(${start.lon}, ${start.lat}, ${ziel.lon}, ${ziel.lat});
        `;

        const daten = result[0];
        if (!daten) {
            alert("Konnte Dauer und Distanz nicht berechnen.");
            return;
        }

        const meter = Math.round(daten.total_length);
        const sekunden = Math.round(daten.total_cost);

        document.getElementById("output").innerHTML =
            `Bushaltestellen-Route:<br>Länge: ${meter} m<br>Dauer: ${sekunden} Sekunden`;

    } catch (err) {
        console.error("Fehler bei Distanz-/Dauerberechnung:", err);
        alert("Fehler bei der Berechnung von Distanz und Dauer.");
    }
}
let fusswegLayerA = null;
let fusswegLayerB = null;

async function zeichneFusswegZurHaltestelle() {
    if (!koordinatenA || !koordinatenB) {
        alert("Bitte zuerst zwei Punkte auf der Karte setzen.");
        return;
    }

    try {
        // 1. Nächste Haltestellen zu A und B holen
        const rows = await sql`
            SELECT point_label, geojson
            FROM nearest_busstops_for_pair(
                ${koordinatenA.lon}, ${koordinatenA.lat},
                ${koordinatenB.lon}, ${koordinatenB.lat}
            );
        `;

        const haltestellen = {};
        rows.forEach(({ point_label, geojson }) => {
            const [lon, lat] = JSON.parse(geojson).coordinates;
            haltestellen[point_label] = { lat, lon };
        });

        // 2. Fußweg von A zur Haltestelle A
        const wegA = await sql`
            SELECT ST_AsGeoJSON(geom)::json AS geom, total_length, total_cost
            FROM calculate_foot_route(
                ${koordinatenA.lon}, ${koordinatenA.lat},
                ${haltestellen["A"].lon}, ${haltestellen["A"].lat}
            );
        `;

        // 3. Fußweg von B zur Haltestelle B
        const wegB = await sql`
            SELECT ST_AsGeoJSON(geom)::json AS geom, total_length, total_cost
            FROM calculate_foot_route(
                ${koordinatenB.lon}, ${koordinatenB.lat},
                ${haltestellen["B"].lon}, ${haltestellen["B"].lat}
            );
        `;

        // 4. Auf Karte anzeigen
        if (fusswegLayerA) map.removeLayer(fusswegLayerA);
        if (fusswegLayerB) map.removeLayer(fusswegLayerB);

        fusswegLayerA = L.geoJSON(wegA[0].geom, {
            style: { color: "green", weight: 3, dashArray: "4, 4" }
        }).addTo(map);

        fusswegLayerB = L.geoJSON(wegB[0].geom, {
            style: { color: "green", weight: 3, dashArray: "4, 4" }
        }).addTo(map);

        // 5. Ausgabe
        const meterA = Math.round(wegA[0].total_length);
        const sekA = Math.round(wegA[0].total_cost);
        const meterB = Math.round(wegB[0].total_length);
        const sekB = Math.round(wegB[0].total_cost);

        document.getElementById("output").innerHTML +=
            `<br><br><b>Fußweg Punkt A zur Haltestelle:</b><br>Länge: ${meterA} m, Dauer: ${sekA} Sekunden` +
            `<br><b>Fußweg Punkt B zur Haltestelle:</b><br>Länge: ${meterB} m, Dauer: ${sekB} Sekunden`;

    } catch (err) {
        console.error("Fehler beim Berechnen des Fußwegs:", err);
        alert("Fehler beim Laden des Fußwegs.");
    }
}



let markerPunkte = []; // speichert max. 2 Marker
let letzterMarker = null;
document.addEventListener("DOMContentLoaded", () => {
    // Kartenevent: Marker setzen bei Klick
    map.on("click", function (e) {
        if (markerPunkte.length >= 2) {
            alert("Bitte zuerst vorhandene Marker löschen.");
            return;
        }

        const { lat, lng } = e.latlng;

        // Marker ohne Popup setzen
        const marker = L.marker([lat, lng]).addTo(map);

        markerPunkte.push({ lat, lon: lng, marker });

        if (markerPunkte.length === 2) {
            document.getElementById("btn-drawRoute").disabled = false;
        }
    });

    // Button: Route berechnen
    document.getElementById("btn-drawRoute").addEventListener("click", () => {
        zeichneRouteVonBushaltestellen();
        berechneDistanzUndDauerZwischenHaltestellen();
        zeichneFusswegZurHaltestelle(); // <--- NEU
    });

    // Button: Zurücksetzen
    document.getElementById("btn-reset").addEventListener("click", () => {
        // Marker entfernen
        markerPunkte.forEach(p => {
            if (p.marker) map.removeLayer(p.marker);
        });
        markerPunkte = [];

        // Koordinaten & Marker zurücksetzen
        koordinatenA = null;
        koordinatenB = null;
        if (markerA) { map.removeLayer(markerA); markerA = null; }
        if (markerB) { map.removeLayer(markerB); markerB = null; }

        // Route entfernen
        if (currentRouteLayer) {
            map.removeLayer(currentRouteLayer);
            currentRouteLayer = null;
        }

        // Linie zwischen Haltestellen entfernen
        if (busstoppLinie) {
            map.removeLayer(busstoppLinie);
            busstoppLinie = null;
        }

        // Haltestellen-Layer entfernen
        haltestellenLayer.forEach(layer => map.removeLayer(layer));
        haltestellenLayer = [];

        // UI zurücksetzen
        document.getElementById("btn-drawRoute").disabled = true;
        document.getElementById("output").innerHTML = "";

        console.log("Zurückgesetzt – Karte ist leer.");
    });

    // Buttons initialisieren
    document.getElementById("btn-drawRoute").disabled = true;
    console.log("Event-Registrierung abgeschlossen");

    // Weitere Button-Events
    document.getElementById("btn-showStopDistance").addEventListener("click", zeigeBushaltestellenEntfernung);
    document.getElementById("btn-loadNextBusStop").addEventListener("click", findeNaechsteHaltestelle);
});