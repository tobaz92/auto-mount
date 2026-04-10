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

macOS 13 minimum.

## Setup

Clic sur l'icone dans la barre de menu > Reglages. Coller l'URL SMB, donner un nom, +, sauvegarder. La premiere fois macOS demande le mot de passe — cocher "se souvenir dans le trousseau" et c'est regle.

## Licence

MIT
