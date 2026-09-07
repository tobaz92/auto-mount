# AutoMount

Petite app menu bar macOS pour monter des partages NAS automatiquement. Fini le Cmd+K dans le Finder.

## Le truc

L'app tourne en fond, check si le NAS est dispo, et monte le partage via le Trousseau macOS. Pas de mot de passe stocke dans l'app, pas de popup, pas de fenetre Finder qui s'ouvre.

Au boot : verifie toutes les minutes pendant 5 min, puis passe en mode tranquille (toutes les 30 min par defaut).

## Build

```
xcode-select --install   # si pas deja fait
./build.sh
open build/AutoMount.app
```

Pour installer dans ~/Applications et relancer l'app en une commande :

```
./build.sh --install
```

macOS 13 minimum.

## Setup

Clic sur l'icone dans la barre de menu > Reglages. Coller l'URL SMB, donner un nom, +, sauvegarder.

L'app monte en mode silencieux : elle ne peut afficher aucune fenetre, donc
elle ne demandera jamais de mot de passe. Le partage doit deja etre dans le
Trousseau. Si ce n'est pas le cas, le monter une fois depuis le Finder (Cmd+K,
coller l'URL, cocher "se souvenir dans le trousseau") — l'app prend le relais
ensuite.

## Licence

MIT
