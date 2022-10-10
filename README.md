# Argos – handschriftliche Quizkarten im Unterricht

Eine kurze Demonstration gibt es hier:

[![](https://img.youtube.com/vi/Rx7wJJPq9iQ/maxresdefault.jpg)](https://youtu.be/Rx7wJJPq9iQ "Argos – handschriftliche Quizkarten im Unterricht")

## Wo gibt es die App?

<a href='https://apps.apple.com/us/app/argos/id6443588390'><img src='assets/app-store-badge.png' style='height: 45px;'/></a>
<a href='https://play.google.com/store/apps/details?id=de.gymnasiumsteglitz.argos'><img src='assets/google-play-badge.png' style='height: 45px;'/></a>

Die App kann auch im Webbrowser verwendet werden: [https://argos.gymnasiumsteglitz.de](https://argos.gymnasiumsteglitz.de).

## Wie funktioniert die App im Unterricht?

Eine Lehrkraft stellt Fragen, die von Schülerinnen und Schülern anonym, kurz und schriftlich auf Antwortkarten beantwortet und anschließend zur Lehrkraft gesendet werden. Die Lehrkraft kann die Karten schließlich in zwei Kategorien sortieren:

* Lösungen, die als »korrekt« akzeptiert werden
* Lösungen, über die noch einmal gesprochen werden soll

Es ist auch möglich, eine Karte zurückzusenden, falls die Antwort in keine der beiden Kategorien fällt. Anschließend können die Antwortkarten z. B. mit Hilfe eines Beamers in der Klasse besprochen werden.

## Wie funktioniert die App technisch?

Die App ist mit Hilfe des fantastischen [Flutter-Frameworks](https://flutter.dev/) programmiert worden. Sie baut eine WebSocket-Verbindung zu einem Backend auf, über die dann die Kommunikation stattfindet. Die beschriebenen Karten werden zwischen den Geräten hin- und hergesendet, befinden sich auf dem Server aber ausschließlich im Arbeitsspeicher – es werden keine Karten in einer Datenbank oder auf einer Festplatte gespeichert. Die Nutzung ist kostenlos und anonym. Wer möchte, kann den Server auch selbst betreiben, der Quelltext für den Server befindet sich [hier](https://github.com/specht/argos-server). Es ist dann nur noch die Variable `argosServer` in `lib/main.dart` anzupassen.
