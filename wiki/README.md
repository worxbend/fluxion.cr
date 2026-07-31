# Wiki source

These pages are the source for the GitHub wiki at
<https://github.com/worxbend/fluxion.cr/wiki>.

They live in the repository so they are reviewed alongside the code that makes
them true, and so a change to behaviour and the page describing it land in the
same commit.

## Publishing

GitHub wikis are a separate git repository that only materialises once the
wiki has been enabled and its first page created through the web UI. Enabling
it through the API is not possible while the repository is private on the free
plan, which is why this is a manual first step rather than a script.

Once the wiki exists:

```bash
git clone git@github.com:worxbend/fluxion.cr.wiki.git /tmp/fluxion-wiki
cp wiki/*.md /tmp/fluxion-wiki/
cd /tmp/fluxion-wiki
rm -f README.md            # this file describes the source, not the wiki
git add -A
git commit -m "docs: sync wiki from the repository"
git push
```

`Home.md` becomes the landing page; the rest are linked from it by filename,
so `[Getting started](Getting-started)` resolves to `Getting-started.md`.

## Pages

| File | Purpose |
|---|---|
| `Home.md` | Landing page and index |
| `Getting-started.md` | From nothing to a working profile |
| `Recipes.md` | Profile patterns worth copying |
| `Troubleshooting.md` | What a message means and what to do |
| `Migrating-from-Java.md` | Moving from the Java implementation |
| `Design-decisions.md` | Why Fluxion refuses certain things |

The reference documentation is deliberately *not* here — it belongs in `docs/`,
versioned with the code it documents. The wiki is for the material that changes
on a different rhythm: recipes, troubleshooting, and reasoning.
