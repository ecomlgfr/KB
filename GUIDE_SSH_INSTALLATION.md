# 🔐 Guide de Configuration SSH pour install-01

## ✅ Ce qui a été fait automatiquement

1. ✓ `.gitignore` mis à jour pour protéger vos credentials
2. ✓ Client OpenSSH installé
3. ✓ Structure `.ssh/` créée avec les bonnes permissions
4. ✓ Fichiers templates préparés

---

## 📋 À FAIRE MAINTENANT - Étape par étape

### ÉTAPE 1️⃣: Convertir votre clé PuTTY en OpenSSH

Depuis votre **ordinateur Windows**, vous devez convertir `private_key.ppk` en format OpenSSH.

**Méthode recommandée - PuTTYgen GUI:**

1. Ouvrez **PuTTYgen** (installé avec PuTTY)
2. Cliquez sur **Load**
3. Naviguez et sélectionnez votre fichier `private_key.ppk`
4. Entrez votre **passphrase** quand demandé
5. Menu **Conversions** → **Export OpenSSH key** (private key)
6. **NE METTEZ PAS** de passphrase supplémentaire quand demandé (cliquez Yes)
7. Sauvegardez comme `private_key_openssh` sur votre bureau

**Alternative - Ligne de commande PowerShell:**
```powershell
# Si vous avez puttygen.exe dans votre PATH
puttygen.exe private_key.ppk -O private-openssh -o private_key_openssh
```

---

### ÉTAPE 2️⃣: Localiser votre dépôt KB sur Windows

Ouvrez **Explorateur de fichiers** et naviguez vers votre dépôt cloné:
```
C:\Users\VotreNom\...\KB\
```

Vérifiez que le dossier `.ssh` existe dedans.

---

### ÉTAPE 3️⃣: Copier la clé SSH convertie

1. Copiez le fichier `private_key_openssh` depuis votre bureau
2. Collez-le dans `KB\.ssh\`
3. **Renommez-le en** `private_key` (sans extension !)

**Résultat attendu:**
```
KB\.ssh\private_key
```

---

### ÉTAPE 4️⃣: Créer le fichier passphrase.txt

1. Dans `KB\.ssh\`, créez un **nouveau fichier texte**
2. Nommez-le **exactement** `passphrase.txt`
3. Ouvrez-le avec Notepad
4. Tapez **uniquement** votre passphrase SSH (le mot de passe de votre clé)
5. **PAS de retour à la ligne** après !
6. Sauvegardez et fermez

**Exemple de contenu:**
```
MonMotDePasseSecret123
```

---

### ÉTAPE 5️⃣: Configurer le fichier config

1. Dans `KB\.ssh\`, trouvez le fichier `config.template`
2. **Copiez-le** et renommez la copie en `config` (sans extension)
3. Ouvrez `config` avec Notepad ou VS Code
4. Remplacez les valeurs entre `< >`:

```
Host install-01
    HostName 192.168.1.XXX           # ← Mettez l'IP de votre serveur
    User root                         # ← Votre username SSH (root, admin, etc.)
    Port 22                           # ← Port SSH (généralement 22)
    IdentityFile ~/.ssh/private_key
    IdentitiesOnly yes
```

**Exemple complété:**
```
Host install-01
    HostName 192.168.1.100
    User root
    Port 22
    IdentityFile ~/.ssh/private_key
    IdentitiesOnly yes
```

5. **Sauvegardez** le fichier `config`

---

### ÉTAPE 6️⃣: Vérifier la structure finale

Dans `KB\.ssh\`, vous devez avoir:

```
.ssh/
├── config                      # ← Votre config personnalisée
├── config.template             # ← Template (peut rester)
├── passphrase.txt              # ← Votre passphrase
├── passphrase.txt.template     # ← Template (peut rester)
├── private_key                 # ← Votre clé SSH convertie
├── README_SETUP.md             # ← Instructions (peut rester)
└── ssh_helper.sh               # ← Script helper (peut rester)
```

**Les fichiers critiques sont:**
- ✅ `config`
- ✅ `passphrase.txt`
- ✅ `private_key`

---

### ÉTAPE 7️⃣: Vérifier que Git ignore bien vos credentials

Depuis votre terminal (PowerShell, Git Bash, ou le terminal VS Code):

```bash
cd KB
git status
```

**Résultat attendu:** Les fichiers `.ssh/private_key`, `.ssh/passphrase.txt`, etc. **NE doivent PAS** apparaître dans les modifications.

Si vous voyez ces fichiers listés, **STOP** et demandez de l'aide !

---

## ✅ C'EST FAIT !

Une fois ces 7 étapes complétées, **revenez me voir** et dites:

**"Les fichiers SSH sont en place"**

Je pourrai alors:
1. Tester la connexion à install-01
2. Exécuter les commandes que vous me donnerez
3. Installer votre infrastructure complète

---

## ❓ Informations dont j'aurai besoin

Pour compléter le fichier `config`, j'ai besoin de connaître:

1. **IP ou hostname** du serveur install-01 → `?`
2. **Username SSH** (root, admin, ubuntu, etc.) → `?`
3. **Port SSH** (généralement 22) → `?`

**Fournissez-moi ces informations dès maintenant** si vous les avez.

---

## 🆘 En cas de problème

**Problème 1:** Je ne trouve pas PuTTYgen
- Solution: Téléchargez PuTTY depuis https://www.putty.org/

**Problème 2:** Mon fichier private_key a une extension .txt
- Solution: Renommez-le pour enlever l'extension (activez "Extensions de noms de fichiers" dans l'Explorateur)

**Problème 3:** Git veut commiter mes fichiers SSH
- Solution: Vérifiez que `.gitignore` contient bien `.ssh/`

**Problème 4:** La conversion de clé ne fonctionne pas
- Solution: Vérifiez que vous utilisez bien la bonne passphrase

---

## 🔒 Rappel Sécurité

**JAMAIS:**
- ❌ Commiter `private_key`, `passphrase.txt` ou `config` sur GitHub
- ❌ Partager ces fichiers par email/chat
- ❌ Les mettre sur un cloud public

**Ces fichiers donnent accès complet à votre serveur !**
