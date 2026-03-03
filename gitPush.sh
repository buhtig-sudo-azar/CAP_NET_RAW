#!/bin/bash

set -e

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "❌ Здесь нет git-репозитория!"
  exit 1
fi

CURRENT_DIR=$(basename "$PWD")
REMOTE_URL=$(git config --get remote.origin.url)
CURRENT_BRANCH=$(git branch --show-current)

echo "------------------------------------------------"
echo "ТЕКУЩИЙ РЕПОЗИТОРИЙ: $CURRENT_DIR"
echo "URL: $REMOTE_URL"
echo "ТЕКУЩАЯ ВЕТКА: $CURRENT_BRANCH"
echo "------------------------------------------------"

echo -n "Введите сообщение коммита: "
read commit_message

if [ -z "$commit_message" ]; then
  echo "Ошибка: Сообщение пустое!"
  exit 1
fi

# 🔥 АВТОМАТИЧЕСКАЯ ОЧИСТКА - отслеживаемые файлы из .gitignore
echo "🧹 Читаем .gitignore..."

# Правильная команда: отслеживаемые файлы, которые теперь игнорируются
IGNORED_TRACKED=$(git ls-files --cached $(git ls-files -co --ignored --exclude-standard | grep -v "^\.gitignore$"))

if [ -n "$IGNORED_TRACKED" ]; then
  echo "⚠️  Найдены ОТСЛЕЖИВАЕМЫЕ файлы для очистки:"
  echo "$IGNORED_TRACKED"
  echo "Удаляем из индекса? [y/N]: "
  read -r confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "$IGNORED_TRACKED" | xargs git rm --cached -f
    git add .gitignore
    git commit -m "🧹 cleanup: sync .gitignore ($(echo "$IGNORED_TRACKED" | wc -l) файлов)"
    echo "✅ Очистка завершена"
  fi
fi

# ВЫБОР ВЕТКИ
echo "ВЕТКИ:"
mapfile -t branches < <(git branch --format="%(refname:short)")
for i in "${!branches[@]}"; do
  if [ "${branches[i]}" = "$CURRENT_BRANCH" ]; then
    printf "  ✓ %d. %s (ТЕКУЩАЯ)\n" $((i+1)) "${branches[i]}"
  else
    printf "   %d. %s\n" $((i+1)) "${branches[i]}"
  fi
done

echo -n "НОМЕР ВЕТКИ (Enter=$CURRENT_BRANCH): "
read choice

if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#branches[@]} ]; then
  branch="${branches[$((choice-1))]}"
elif [ -z "$choice" ]; then
  branch="$CURRENT_BRANCH"
else
  echo "НЕВЕРНЫЙ ВЫБОР!"
  exit 1
fi

echo "ВЫБРАНА: $branch"

# ПЕРЕКЛЮЧЕНИЕ НА ВЕТКУ
if [ "$branch" != "$CURRENT_BRANCH" ]; then
  git stash push -m "temp auto-stash" 2>/dev/null || true
  git checkout "$branch"
  git stash pop 2>/dev/null || true
  CURRENT_BRANCH=$(git branch --show-current)
fi

# ✅ ФИНАЛЬНАЯ ПРОВЕРКА ПЕРЕД КОММИТОМ
git add .

# Проверяем статус - показываем что будет добавлено
echo "📋 СТАТУС ДО КОММИТА:"
git status --short

if git diff --cached --quiet; then
  echo "ℹ️ Нет изменений для коммита"
  exit 0
fi

echo "📋 Будет добавлено файлов: $(git diff --cached --name-only | wc -l)"
echo "Отправить? [y/N]: "
read -r final_confirm

if [[ "$final_confirm" =~ ^[Yy]$ ]]; then
  git commit -m "$commit_message"
  echo "🎉 Коммит создан!"
  
  # PUSH с проверкой
  if git push origin "$CURRENT_BRANCH"; then
    echo "✅ ГОТОВО! Отправлено в $CURRENT_BRANCH"
  else
    echo "❌ Ошибка push. Проверьте интернет/права."
  fi
else
  echo "❌ Отменено"
  git reset
fi
