// Shared seed for the Lists WebKit tests and screenshots: 12 items across the
// real default categories, one long name, one note, 2 checked, 2 lists.
import C from './lists-load.mjs';

export function richState() {
  const s = C.newState();
  s.lists.push({ id: 'list-costco', name: 'Costco run', order: 1, updatedAt: 1, deleted: false });
  const rows = [
    ['Bananas', 'Produce'], ['Spinach', 'Produce'], ['Sourdough loaf', 'Bakery'], ['Milk', 'Dairy'], ['Greek yogurt', 'Dairy'],
    ['Chicken thighs', 'Meat & Seafood'], ['Frozen peas', 'Frozen'], ['Pasta', 'Pantry'],
    ['Extra virgin olive oil in the big tin from the Italian shop on the corner, the cold-pressed one', 'Pantry'],
    ['Tortilla chips', 'Snacks'], ['Sparkling water', 'Beverages'], ['Dish soap', 'Household']
  ];
  rows.forEach(([name, cat], i) => {
    s.items.push({
      id: 'i' + i, listId: 'list-groceries', name, note: name === 'Milk' ? 'oat, not dairy, the barista kind' : '',
      categoryId: 'cat-' + cat.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/g, ''),
      checked: name === 'Pasta' || name === 'Dish soap', createdAt: 1000 + i, updatedAt: 1000 + i, deleted: false,
      history: [{ at: Date.now() - 3600e3 * (i + 1), what: 'Added' }]
    });
  });
  s.items.push({ id: 'c0', listId: 'list-costco', name: 'Paper towels', note: '', categoryId: 'cat-household', checked: false, createdAt: 1, updatedAt: 1, deleted: false, history: [{ at: 1, what: 'Added' }] });
  return s;
}
