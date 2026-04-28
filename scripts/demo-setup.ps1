# ─────────────────────────────────────────────────────────────────────────────
#  GYT - Script de preparation de demo
#
#  Cree :
#    • 4 comptes utilisateurs (alice, bob, charlie, diana)
#    • 1 organisation (gyt-demo) avec membres
#    • Depots publics, prives, et repos de profil (README)
#    • Commits reels via git push SSH
#    • Labels, issues, pull requests avec commentaires
#
#  Prerequis :
#    • PowerShell 7+ (pwsh) ou Windows PowerShell 5.1
#    • git installe et dans le PATH
#    • ssh-keygen disponible (fourni avec Git for Windows ou OpenSSH Windows)
#
#  Usage :
#    .\demo-setup.ps1
#    .\demo-setup.ps1 -Url "https://git.lucamorgado.com" -Verbose
#    .\demo-setup.ps1 -CleanupOnly   # supprime uniquement les donnees creees
# ─────────────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [string]$Url          = "https://git.lucamorgado.com",
    [switch]$CleanupOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Bypass SSL pour PowerShell 5.1 (compatible PS 7 aussi) ──────────────────
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# ─── Couleurs ─────────────────────────────────────────────────────────────────
function Write-Step   { param($msg) Write-Host "`n▶  $msg" -ForegroundColor Cyan }
function Write-OK     { param($msg) Write-Host "   ✓ $msg" -ForegroundColor Green }
function Write-Warn   { param($msg) Write-Host "   ⚠ $msg" -ForegroundColor Yellow }
function Write-Creds  { param($msg) Write-Host "   $msg" -ForegroundColor Magenta }

# ─── Configuration des comptes de demo ────────────────────────────────────────
$GQL_URL   = "$Url/graphql"
# URL de base pour les push HTTPS (credentials injectes par repo)
$HTTP_GIT_BASE = $Url   # ex: https://git.lucamorgado.com
$WORK_DIR  = Join-Path $env:TEMP "gyt-demo-$([System.IO.Path]::GetRandomFileName().Split('.')[0])"

$USERS = @(
    @{ username = "alice";   password = "Demo@Alice2026";   email = "alice@gyt-demo.dev";   displayName = "Alice Martin" }
    @{ username = "bob";     password = "Demo@Bob2026";     email = "bob@gyt-demo.dev";     displayName = "Bob Dupont" }
    @{ username = "charlie"; password = "Demo@Charlie2026"; email = "charlie@gyt-demo.dev"; displayName = "Charlie Leroy" }
    @{ username = "diana";   password = "Demo@Diana2026";   email = "diana@gyt-demo.dev";   displayName = "Diana Moreau" }
)

$ORG_NAME = "gyt-demo"

# Tokens JWT par utilisateur (remplis pendant l'execution)
$tokens = @{}

# ─── Helpers GraphQL ──────────────────────────────────────────────────────────
function Invoke-GQL {
    param(
        [string]   $Query,
        [hashtable]$Variables = @{},
        [string]   $Token     = $null
    )
    $headers = @{ "Content-Type" = "application/json; charset=utf-8" }
    if ($Token) { $headers["Authorization"] = "Bearer $Token" }

    $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 10 -Compress
    # PS 5.1 encode les strings en Windows-1252 par defaut → forcer UTF-8 explicitement
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    try {
        $resp = Invoke-RestMethod `
            -Uri     $GQL_URL `
            -Method  Post `
            -Headers $headers `
            -Body    $bodyBytes
    }
    catch {
        Write-Warn "Erreur HTTP : $_"
        return $null
    }

    if ($resp.PSObject.Properties['errors'] -and $resp.errors) {
        $msg = ($resp.errors | ForEach-Object { $_.message }) -join " | "
        Write-Warn "GraphQL : $msg"
        return $null
    }
    if (-not ($resp.PSObject.Properties['data'])) { return $null }
    return $resp.data
}

# ─── Git helpers ──────────────────────────────────────────────────────────────
function Invoke-Git {
    param([string]$WorkDir, [string[]]$GitArgs)
    $env:GIT_SSL_NO_VERIFY = "true"
    Push-Location $WorkDir
    try {
        # ErrorActionPreference = Stop ferait planter sur le moindre stderr de git
        # (ex: "To https://..." est ecrit sur stderr par git, meme en cas de succes)
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $gitOutput = & git @GitArgs 2>&1
        $ErrorActionPreference = $prevEAP

        $gitOutput | ForEach-Object { Write-Verbose "   git: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "git $($GitArgs -join ' ') => exit $LASTEXITCODE"
            $gitOutput | ForEach-Object { Write-Host "      | $_" -ForegroundColor DarkYellow }
        }
    } finally {
        Pop-Location
        Remove-Item Env:\GIT_SSL_NO_VERIFY -ErrorAction SilentlyContinue
    }
}

function New-RepoWithContent {
    param(
        [string]   $Owner,
        [string]   $RepoName,
        [string]   $Password,
        [string[]] $Branches    = @("main"),
        [hashtable]$FilesPerBranch = @{}  # branchName -> @{ path = content }
    )

    $repoDir = Join-Path $WORK_DIR "$Owner-$RepoName"
    New-Item -ItemType Directory -Path $repoDir -Force | Out-Null

    Invoke-Git $repoDir @("init", "-b", "main")
    Invoke-Git $repoDir @("config", "user.email", "$Owner@gyt-demo.dev")
    Invoke-Git $repoDir @("config", "user.name", $Owner)

    # Branche main en premier
    if ($FilesPerBranch.ContainsKey("main")) {
        foreach ($kv in $FilesPerBranch["main"].GetEnumerator()) {
            $filePath = Join-Path $repoDir $kv.Key
            $dirPath  = Split-Path $filePath -Parent
            if ($dirPath -ne $repoDir) { New-Item -ItemType Directory -Path $dirPath -Force | Out-Null }
            Set-Content -Path $filePath -Value $kv.Value -Encoding UTF8
        }
    } else {
        # README minimal si aucun contenu specifie
        Set-Content -Path (Join-Path $repoDir "README.md") -Value "# $RepoName`n" -Encoding UTF8
    }

    Invoke-Git $repoDir @("add", ".")
    Invoke-Git $repoDir @("commit", "-m", "Initial commit")

    # URL HTTPS avec credentials : https://user:password@host/owner/repo.git
    $creds     = [Uri]::EscapeDataString($Password)
    $remoteUrl = "$HTTP_GIT_BASE/$Owner/$RepoName.git" -replace 'https://', "https://${Owner}:${creds}@"
    Invoke-Git $repoDir @("remote", "add", "origin", $remoteUrl)
    Invoke-Git $repoDir @("push", "-u", "origin", "main")

    # Branches supplementaires
    foreach ($branch in ($Branches | Where-Object { $_ -ne "main" })) {
        Invoke-Git $repoDir @("checkout", "-b", $branch)
        if ($FilesPerBranch.ContainsKey($branch)) {
            foreach ($kv in $FilesPerBranch[$branch].GetEnumerator()) {
                $filePath = Join-Path $repoDir $kv.Key
                $dirPath  = Split-Path $filePath -Parent
                if ($dirPath -ne $repoDir) { New-Item -ItemType Directory -Path $dirPath -Force | Out-Null }
                Set-Content -Path $filePath -Value $kv.Value -Encoding UTF8
            }
        } else {
            $placeholder = Join-Path $repoDir "changes-$branch.md"
            Set-Content -Path $placeholder -Value "# Changements branche $branch`n" -Encoding UTF8
        }
        Invoke-Git $repoDir @("add", ".")
        Invoke-Git $repoDir @("commit", "-m", "feat: ajout contenu branche $branch")
        Invoke-Git $repoDir @("push", "-u", "origin", $branch)
        Invoke-Git $repoDir @("checkout", "main")
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MODE CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════
if ($CleanupOnly) {
    Write-Step "Mode nettoyage - connexion en tant qu alice"
    $loginData = Invoke-GQL -Query 'mutation L($i:LoginInput!){login(input:$i){accessToken}}' `
                             -Variables @{ i = @{ login = "alice"; password = "Demo@Alice2026" } }
    if (-not $loginData) { Write-Warn "Impossible de se connecter en tant qu alice, abandon." ; exit 1 }
    $aliceToken = $loginData.login.accessToken

    foreach ($repo in @("alice", "demo-webapp", "private-config")) {
        Invoke-GQL -Query 'mutation D($o:String!,$n:String!){deleteRepository(owner:$o,name:$n)}' `
                   -Variables @{ o = "alice"; n = $repo } -Token $aliceToken | Out-Null
    }
    foreach ($repo in @("bob", "awesome-app")) {
        $bobLogin = Invoke-GQL -Query 'mutation L($i:LoginInput!){login(input:$i){accessToken}}' `
                               -Variables @{ i = @{ login = "bob"; password = "Demo@Bob2026" } }
        if ($bobLogin) {
            Invoke-GQL -Query 'mutation D($o:String!,$n:String!){deleteRepository(owner:$o,name:$n)}' `
                       -Variables @{ o = "bob"; n = $repo } -Token $bobLogin.login.accessToken | Out-Null
        }
    }
    Invoke-GQL -Query 'mutation DO($n:String!){deleteOrganization(name:$n)}' `
               -Variables @{ n = "gyt-demo" } -Token $aliceToken | Out-Null
    Write-OK "Nettoyage termine."
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  DEBUT DU SETUP
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          GYT - Preparation de la demonstration            ║" -ForegroundColor Cyan
Write-Host "║          Cible : $Url" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ─── 0. Repertoire de travail ──────────────────────────────────────────────────
New-Item -ItemType Directory -Path $WORK_DIR -Force | Out-Null
Write-Step "Repertoire temporaire : $WORK_DIR"

# ─── 1. Creation des comptes utilisateurs ─────────────────────────────────────
Write-Step "Creation des comptes utilisateurs"

$REGISTER_MUTATION = @'
mutation Register($input: RegisterInput!) {
  register(input: $input) {
    accessToken
    refreshToken
    user { uuid username email displayName }
  }
}
'@

foreach ($u in $USERS) {
    $data = Invoke-GQL -Query $REGISTER_MUTATION -Variables @{
        input = @{
            username    = $u.username
            email       = $u.email
            password    = $u.password
            displayName = $u.displayName
        }
    }
    if ($data -and $data.register) {
        $tokens[$u.username] = $data.register.accessToken
        Write-OK "$($u.username) cree - token OK"
    } else {
        # Le compte existe peut-etre deja, essayer le login
        $loginData = Invoke-GQL `
            -Query 'mutation L($i:LoginInput!){login(input:$i){accessToken refreshToken user{uuid}}}' `
            -Variables @{ i = @{ login = $u.username; password = $u.password } }
        if ($loginData -and $loginData.login) {
            $tokens[$u.username] = $loginData.login.accessToken
            Write-Warn "$($u.username) existait deja - token recupere via login"
        } else {
            Write-Warn "$($u.username) : impossible de creer ou d'authentifier"
        }
    }
}

# ─── 3. Creation de l'organisation ────────────────────────────────────────────
Write-Step "Creation de l'organisation '$ORG_NAME'"
$orgData = Invoke-GQL `
    -Query 'mutation O($i:CreateOrgInput!){createOrganization(input:$i){name displayName}}' `
    -Variables @{ i = @{ name = $ORG_NAME; displayName = "GYT Demo Org"; description = "Organisation de demonstration GYT" } } `
    -Token $tokens["alice"]

if ($orgData) {
    Write-OK "Organisation '$ORG_NAME' creee"

    # Ajout des membres
    foreach ($member in @("bob", "charlie", "diana")) {
        if ($tokens[$member]) {
            $role = if ($member -eq "bob") { "owner" } else { "member" }
            $addM = Invoke-GQL `
                -Query 'mutation AM($i:AddOrgMemberInput!){addOrgMember(input:$i){role}}' `
                -Variables @{ i = @{ orgName = $ORG_NAME; username = $member; role = $role } } `
                -Token $tokens["alice"]
            if ($addM) { Write-OK "$member ajoute a $ORG_NAME (role : $role)" }
        }
    }
}

# ─── 5. Creation des depots via GraphQL ───────────────────────────────────────
Write-Step "Creation des depots"

$CREATE_REPO = 'mutation CR($i:CreateRepoInput!){createRepository(input:$i){name ownerName isPrivate}}'

$repos = @(
    @{ owner = "alice";  name = "alice";           isPrivate = $false; token = $tokens["alice"];   desc = "Profil README d'alice" }
    @{ owner = "alice";  name = "demo-webapp";     isPrivate = $false; token = $tokens["alice"];   desc = "Application web de démonstration GYT" }
    @{ owner = "alice";  name = "private-config";  isPrivate = $true;  token = $tokens["alice"];   desc = "Configuration privee - ne pas partager" }
    @{ owner = "bob";    name = "bob";             isPrivate = $false; token = $tokens["bob"];     desc = "Profil README de bob" }
    @{ owner = "bob";    name = "awesome-app";     isPrivate = $false; token = $tokens["bob"];     desc = "Application de bob" }
)

# Repo org (owner = gyt-demo)
if ($orgData) {
    $repos += @{ owner = "alice"; name = "platform"; isPrivate = $false; token = $tokens["alice"];
                 orgName = $ORG_NAME; desc = "Plateforme principale GYT Demo" }
}

foreach ($r in $repos) {
    if (-not $r.token) { Write-Warn "Pas de token pour $($r.owner)/$($r.name), ignore" ; continue }

    $input = @{ name = $r.name; description = $r.desc; isPrivate = $r.isPrivate }
    if ($r.ContainsKey("orgName")) { $input["orgName"] = $r.orgName }

    $rData = Invoke-GQL -Query $CREATE_REPO -Variables @{ i = $input } -Token $r.token
    if ($rData) {
        $vis = if ($r.isPrivate) { "prive" } else { "public" }
        Write-OK "$($r.owner)/$($r.name) cree [$vis]"
    } else {
        Write-Warn "$($r.owner)/$($r.name) - creation echouee (existe peut-etre deja)"
    }
}

# ─── 6. Push git (contenu reel) ───────────────────────────────────────────────
Write-Step "Push git - contenu des depots"

# ── alice/alice (profil README) ──
Write-Verbose "Push alice/alice"
New-RepoWithContent -Owner "alice" -RepoName "alice" -Password "Demo@Alice2026" -FilesPerBranch @{
    "main" = @{
        "README.md" = @"
<h1 align="center">Alice Martin</h1>
<p align="center">Ingénieure logiciel · Paris · alice@gyt-demo.dev</p>

---

## Projets
| Projet | Description | Statut |
|--------|-------------|--------|
| [demo-webapp](../demo-webapp) | Application web GYT | ✅ Actif |
| [private-config](../private-config) | Config privee | 🔒 Prive |

## Langages
![Go](https://img.shields.io/badge/Go-00ADD8?style=flat&logo=go&logoColor=white)
![TypeScript](https://img.shields.io/badge/TypeScript-3178C6?style=flat&logo=typescript&logoColor=white)
"@
    }
}
Write-OK "alice/alice pousse"

# ── alice/demo-webapp (avec branche feature pour la PR) ──
Write-Verbose "Push alice/demo-webapp"
New-RepoWithContent -Owner "alice" -RepoName "demo-webapp" -Password "Demo@Alice2026" `
    -Branches @("main", "feature/login-page", "feature/dark-mode") `
    -FilesPerBranch @{
    "main" = @{
        "README.md"     = "# demo-webapp`n`nApplication web de démonstration GYT.`n`n## Stack`n- Go backend`n- Next.js frontend`n- PostgreSQL`n"
        "src/index.ts"  = "// Point d'entree de l'application`nconsole.log('GYT demo-webapp v0.1.0');"
        "src/app.ts"    = @"
import express from 'express';
const app = express();

app.get('/', (_req, res) => {
  res.json({ status: 'ok', app: 'demo-webapp' });
});

app.listen(3000, () => console.log('Listening on :3000'));
"@
        "package.json"  = '{"name":"demo-webapp","version":"0.1.0","scripts":{"start":"ts-node src/index.ts"}}'
        ".gitignore"    = "node_modules/`ndist/`n.env`n"
    }
    "feature/login-page" = @{
        "src/login.ts" = @"
// Page de connexion
export interface LoginCredentials {
  username: string;
  password: string;
}

export async function login(creds: LoginCredentials): Promise<string> {
  const response = await fetch('/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      query: `mutation Login(`$`$i: LoginInput!) { login(input: `$`$i) { accessToken } }`,
      variables: { i: creds }
    })
  });
  const data = await response.json();
  return data.data.login.accessToken;
}
"@
        "src/components/LoginForm.tsx" = @"
// Composant formulaire de connexion
import React, { useState } from 'react';

export function LoginForm({ onSuccess }: { onSuccess: (token: string) => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    // TODO: appel API
  };

  return (
    <form onSubmit={handleSubmit}>
      <input value={username} onChange={e => setUsername(e.target.value)} placeholder="Nom d'utilisateur" />
      <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="Mot de passe" />
      <button type="submit">Connexion</button>
    </form>
  );
}
"@
    }
    "feature/dark-mode" = @{
        "src/theme.ts" = @"
// Gestion du theme clair/sombre
export type Theme = 'light' | 'dark';

export function getSystemTheme(): Theme {
  if (typeof window === 'undefined') return 'light';
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export function applyTheme(theme: Theme) {
  document.documentElement.setAttribute('data-theme', theme);
  localStorage.setItem('gyt-theme', theme);
}
"@
    }
}
Write-OK "alice/demo-webapp pousse (branches: main, feature/login-page, feature/dark-mode)"

# ── bob/bob (profil README) ──
Write-Verbose "Push bob/bob"
New-RepoWithContent -Owner "bob" -RepoName "bob" -Password "Demo@Bob2026" -FilesPerBranch @{
    "main" = @{
        "README.md" = @"
<h1 align="center">Bob Dupont</h1>
<p align="center">Développeur fullstack · bob@gyt-demo.dev</p>

---

## Contributions récentes
- Review de [demo-webapp#1](../alice/demo-webapp) - feature/login-page
- Membre de l'organisation [gyt-demo](../gyt-demo)
"@
    }
}
Write-OK "bob/bob pousse"

# ── bob/awesome-app ──
Write-Verbose "Push bob/awesome-app"
New-RepoWithContent -Owner "bob" -RepoName "awesome-app" -Password "Demo@Bob2026" -FilesPerBranch @{
    "main" = @{
        "README.md"  = "# awesome-app`n`nApplication de Bob.`n"
        "main.go"    = @"
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "Hello from awesome-app!")
	})
	fmt.Println("Listening on :8080")
	http.ListenAndServe(":8080", nil)
}
"@
        "go.mod" = "module awesome-app`n`ngo 1.23`n"
    }
}
Write-OK "bob/awesome-app pousse"

# ─── 7. Ajout de bob comme collaborateur sur demo-webapp ──────────────────────
Write-Step "Ajout de bob comme collaborateur sur alice/demo-webapp"
$collabData = Invoke-GQL `
    -Query 'mutation AC($i:AddCollaboratorInput!){addCollaborator(input:$i)}' `
    -Variables @{ i = @{ owner = "alice"; name = "demo-webapp"; username = "bob"; accessLevel = "write" } } `
    -Token $tokens["alice"]
if ($collabData) { Write-OK "bob ajoute comme collaborateur (write)" }

# ─── 8. Labels sur alice/demo-webapp ─────────────────────────────────────────
Write-Step "Creation des labels sur alice/demo-webapp"
$labels = @(
    @{ name = "bug";         color = "d73a4a"; description = "Quelque chose ne fonctionne pas" }
    @{ name = "enhancement"; color = "a2eeef"; description = "Nouvelle fonctionnalité ou amélioration" }
    @{ name = "good first issue"; color = "7057ff"; description = "Bon pour les nouveaux contributeurs" }
    @{ name = "documentation"; color = "0075ca"; description = "Amélioration de la doc" }
    @{ name = "review needed"; color = "e4e669"; description = "Demande de review" }
)
foreach ($lbl in $labels) {
    $lData = Invoke-GQL `
        -Query 'mutation CL($i:CreateLabelInput!){createLabel(input:$i){name color}}' `
        -Variables @{ i = @{ owner = "alice"; repo = "demo-webapp"; name = $lbl.name; color = $lbl.color; description = $lbl.description } } `
        -Token $tokens["alice"]
    if ($lData) { Write-OK "Label '$($lbl.name)' cree" }
}

# ─── 9. Issues sur alice/demo-webapp ─────────────────────────────────────────
Write-Step "Creation des issues sur alice/demo-webapp"
$issues = @(
    @{
        title = "Ajouter la validation côté client du formulaire de login"
        body  = "Le formulaire `LoginForm` ne valide pas les champs avant l'envoi. Il faudrait :`n- Vérifier que le username n'est pas vide`n- Vérifier que le password fait au moins 8 caractères`n- Afficher des messages d'erreur inline"
        labels = @("enhancement", "good first issue")
    }
    @{
        title = "Bug : le token n'est pas invalidé à la déconnexion"
        body  = "Après un logout, le JWT est encore valide jusqu'à son expiration naturelle. Il faut ajouter le token à une blocklist Redis."
        labels = @("bug")
    }
    @{
        title = "Documenter l'API GraphQL"
        body  = "La documentation du schéma GraphQL n'est pas encore générée. Utiliser `@deprecated` et des descriptions de champs pour alimenter le Playground."
        labels = @("documentation")
    }
)
$issueNumbers = @()
foreach ($iss in $issues) {
    $iData = Invoke-GQL `
        -Query 'mutation CI($i:CreateIssueInput!){createIssue(input:$i){number title}}' `
        -Variables @{ i = @{ owner = "alice"; repo = "demo-webapp"; title = $iss.title; body = $iss.body; labels = $iss.labels } } `
        -Token $tokens["alice"]
    if ($iData -and $iData.createIssue) {
        $issueNumbers += $iData.createIssue.number
        Write-OK "Issue #$($iData.createIssue.number) : $($iss.title)"
    }
}

# Commentaire de charlie sur la premiere issue
if ($issueNumbers.Count -gt 0 -and $tokens["charlie"]) {
    Invoke-GQL `
        -Query 'mutation CIC($o:String!,$r:String!,$n:Int!,$b:String!){createIssueComment(owner:$o,repo:$r,number:$n,body:$b){id}}' `
        -Variables @{ o = "alice"; r = "demo-webapp"; n = $issueNumbers[0]; b = "Je peux m'en charger ! Je regarde la lib `zod` pour la validation côté client." } `
        -Token $tokens["charlie"] | Out-Null
    Write-OK "Charlie a commente l'issue #$($issueNumbers[0])"
}

# ─── 10. Pull Requests ────────────────────────────────────────────────────────
Write-Step "Creation des Pull Requests"

# PR 1 : feature/login-page → main (creee par bob)
$pr1 = Invoke-GQL `
    -Query 'mutation CPR($i:CreatePRInput!){createPullRequest(input:$i){number title state}}' `
    -Variables @{
        i = @{
            owner      = "alice"
            repo       = "demo-webapp"
            title      = "feat: ajout de la page de connexion"
            body       = "## Description`nAjoute le composant `LoginForm` et la fonction `login()` pour l'authentification via GraphQL.`n`n## Changements`n- `src/login.ts` : fonction d'appel à la mutation `login``n- `src/components/LoginForm.tsx` : composant React formulaire`n`n## Tests`n- [ ] Test manuel du formulaire`n- [ ] Vérification que le token est bien stocké`n`nFixes #$($issueNumbers | Select-Object -First 1)"
            headBranch = "feature/login-page"
            baseBranch = "main"
            assignees  = @("alice")
            labels     = @("enhancement", "review needed")
        }
    } -Token $tokens["bob"]

if ($pr1 -and $pr1.createPullRequest) {
    $prNum = $pr1.createPullRequest.number
    Write-OK "PR #$prNum creee : $($pr1.createPullRequest.title)"

    # Commentaire de charlie sur la PR
    if ($tokens["charlie"]) {
        Invoke-GQL `
            -Query 'mutation CPRC($i:CreatePRCommentInput!){createPRComment(input:$i){id}}' `
            -Variables @{ i = @{ owner = "alice"; repo = "demo-webapp"; number = $prNum; body = "Super travail ! J'ai quelques suggestions sur la gestion des erreurs dans `login.ts`." } } `
            -Token $tokens["charlie"] | Out-Null
        Write-OK "Charlie a commente la PR #$prNum"
    }

    # Review d'approbation de diana
    if ($tokens["diana"]) {
        $rv = Invoke-GQL `
            -Query 'mutation CPRV($i:CreatePRReviewInput!){createPRReview(input:$i){id state}}' `
            -Variables @{ i = @{ owner = "alice"; repo = "demo-webapp"; number = $prNum; state = "APPROVED"; body = "Code propre, bien structure. LGTM ! ✅" } } `
            -Token $tokens["diana"]
        if ($rv) { Write-OK "Diana a approuve la PR #$prNum" }
    }

    # Demande de review a charlie
    Invoke-GQL `
        -Query 'mutation RR($o:String!,$r:String!,$n:Int!,$u:String!){requestReview(owner:$o,repo:$r,number:$n,username:$u)}' `
        -Variables @{ o = "alice"; r = "demo-webapp"; n = $prNum; u = "charlie" } `
        -Token $tokens["alice"] | Out-Null
    Write-OK "Review demandee a charlie sur PR #$prNum"
}

# PR 2 : feature/dark-mode → main (creee par alice, laissee ouverte)
$pr2 = Invoke-GQL `
    -Query 'mutation CPR($i:CreatePRInput!){createPullRequest(input:$i){number title}}' `
    -Variables @{
        i = @{
            owner      = "alice"
            repo       = "demo-webapp"
            title      = "feat: support du mode sombre"
            body       = "Ajoute la detection du theme systeme et la persistance dans localStorage.`n`nRelated to #$($issueNumbers | Select-Object -First 1 -Skip 0)"
            headBranch = "feature/dark-mode"
            baseBranch = "main"
            labels     = @("enhancement")
        }
    } -Token $tokens["alice"]

if ($pr2 -and $pr2.createPullRequest) {
    Write-OK "PR #$($pr2.createPullRequest.number) creee : $($pr2.createPullRequest.title)"
}

# ─── 11. Stars ────────────────────────────────────────────────────────────────
Write-Step "Stars croisees"
$starPairs = @(
    @{ user = "bob";     token = $tokens["bob"];     owner = "alice"; repo = "demo-webapp" }
    @{ user = "charlie"; token = $tokens["charlie"]; owner = "alice"; repo = "demo-webapp" }
    @{ user = "diana";   token = $tokens["diana"];   owner = "alice"; repo = "demo-webapp" }
    @{ user = "alice";   token = $tokens["alice"];   owner = "bob";   repo = "awesome-app" }
)
foreach ($s in $starPairs) {
    if (-not $s.token) { continue }
    $sData = Invoke-GQL `
        -Query 'mutation S($o:String!,$n:String!){starRepository(owner:$o,name:$n)}' `
        -Variables @{ o = $s.owner; n = $s.repo } -Token $s.token
    if ($sData) { Write-OK "$($s.user) ⭐ $($s.owner)/$($s.repo)" }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  RECAPITULATIF DES ACCES
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║                 COMPTES DE DEMONSTRATION GYT                    ║" -ForegroundColor Magenta
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║  URL         : $Url" -ForegroundColor Magenta
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Creds "  COMPTE          MOT DE PASSE         ROLE"
Write-Creds "  ─────────────────────────────────────────────────────────────"
foreach ($u in $USERS) {
    $role = if ($u.username -eq "alice") { "Proprietaire des repos, admin org" }
            elseif ($u.username -eq "bob") { "Collaborateur, co-owner org" }
            else { "Membre org" }
    Write-Creds ("  {0,-15} {1,-22} {2}" -f $u.username, $u.password, $role)
}
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Creds "  DEPOTS CREES"
Write-Creds "  ─────────────────────────────────────────────────────────────"
Write-Creds "  alice/alice          Profil README (public)"
Write-Creds "  alice/demo-webapp    App demo avec PRs et issues (public)"
Write-Creds "  alice/private-config Config privee (prive)"
Write-Creds "  bob/bob              Profil README (public)"
Write-Creds "  bob/awesome-app      App Go (public)"
Write-Creds "  gyt-demo/platform    Repo d'organisation (public)"
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Creds "  ELEMENTS NOTABLES POUR LA DEMO"
Write-Creds "  ─────────────────────────────────────────────────────────────"
Write-Creds "  • alice/demo-webapp : 2 PRs ouvertes + issues + labels + stars"
Write-Creds "  • PR #1 (feature/login-page) : review diana APPROVED, review charlie demandee"
Write-Creds "  • Organisation gyt-demo : alice (admin), bob (owner), charlie+diana (member)"
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Repertoire git  : $WORK_DIR" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Pour supprimer les donnees : .\demo-setup.ps1 -CleanupOnly" -ForegroundColor DarkGray
Write-Host ""
