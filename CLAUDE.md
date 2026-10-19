# KickBack

App macOS que roda jogos do Windows: `app/KickBack.swift` (SwiftUI) chama `kb` (bash), que roda o
Wine compilado por `build-runtime.sh` em `runtime/`. Detalhes em `README.md`.

## Publicar uma versão nova

1. Teste: `./test.sh`. Se mexeu no runtime, recompile só as etapas afetadas
   (`./build-runtime.sh wine builtin shim`, por exemplo). Não edite o `build-runtime.sh` enquanto ele roda,
   porque o bash lê o script aos poucos.
2. Gere o DMG assinado e notarizado (leva de 5 a 10 minutos):
   ```bash
   SIGN_ID="Developer ID Application: Joao Simi (PDA9JTMKC5)" NOTARY_PROFILE=kickback VERSION=X.Y.Z ./package.sh
   ```
   Isso usa o certificado Developer ID e o perfil `kickback` do `notarytool`, ambos no Keychain.
   Sem essas variáveis, o pacote sai ad-hoc e o macOS bloqueia na primeira abertura.
3. Confira: `spctl -a -t open --context context:primary-signature -v dist/KickBack.dmg` precisa mostrar
   `source=Notarized Developer ID`.
4. Crie o release. O asset tem que se chamar `KickBack.dmg`, porque o site e o README apontam para
   `releases/latest/download/KickBack.dmg`:
   ```bash
   gh release create vX.Y.Z dist/KickBack.dmg build/release-src/kickback-sources-X.Y.Z.tar.gz \
     build/crossover-sources-26.3.0.tar.gz --repo JGSimi/kickback --title "KickBack X.Y.Z" --notes-file notas.md
   ```
   Os tarballs de código-fonte são exigidos pelas licenças LGPL. Refaça o `kickback-sources` se mudar a
   versão de algum componente (veja `THIRD_PARTY_NOTICES.md`). Para só trocar o DMG de um release
   existente: `gh release upload vX.Y.Z dist/KickBack.dmg --clobber --repo JGSimi/kickback`.
5. Site: atualize a versão e o tamanho em `site/index.html` (texto "Versão 0.1.0, download de 401 MB.")
   e publique com `cd site && vercel deploy --prod --yes` (projeto Vercel `kickback`, https://kickback-ten.vercel.app).
   O `site/.vercelignore` impede que `.env*` seja enviado.
6. Faça commit e push.
