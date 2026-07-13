import { DatabaseSync } from 'node:sqlite';

function normalizeParams(params) {
  const bound = new Array(params.length);
  for (let i = 0; i < params.length; i++) {
    bound[i] = params[i] === undefined ? null : params[i];
  }
  return bound;
}

function normalizeResult(result) {
  let lastInsertRowid = result.lastInsertRowid;
  if (typeof lastInsertRowid === 'bigint') {
    lastInsertRowid = Number(lastInsertRowid);
  }
  return { changes: result.changes, insertId: lastInsertRowid };
}

export class WrappedDatabase {
  constructor(db) {
    this.db = db;
    this.savepointId = 0;
  }

  /**
   * @param {string} sql
   * @param {(string | number | null | undefined)[]} params
   */
  all(sql, params = []) {
    const stmt = this.db.prepare(sql);
    return stmt.all(...normalizeParams(params));
  }

  /**
   * @param {string} sql
   * @param {(string | number | null | undefined)[]} params
   */
  first(sql, params = []) {
    const stmt = this.db.prepare(sql);
    return stmt.get(...normalizeParams(params)) ?? null;
  }

  /**
   * @param {string} sql
   */
  exec(sql) {
    return this.db.exec(sql);
  }

  /**
   * @param {string} sql
   * @param {(string | number | null | undefined)[]} params
   */
  mutate(sql, params = []) {
    const stmt = this.db.prepare(sql);
    const info = stmt.run(...normalizeParams(params));
    return normalizeResult(info);
  }

  /**
   * @param {() => void} fn
   */
  transaction(fn) {
    const nested = this.db.isTransaction;
    if (nested) {
      this.savepointId += 1;
    }
    const name = nested ? `__sp${this.savepointId}__` : null;
    this.exec(nested ? `SAVEPOINT ${name}` : 'BEGIN');
    try {
      const result = fn();
      this.exec(nested ? `RELEASE ${name}` : 'COMMIT');
      return result;
    } catch (err) {
      this.exec(nested ? `ROLLBACK TO ${name}` : 'ROLLBACK');
      if (nested) {
        this.exec(`RELEASE ${name}`);
      }
      throw err;
    }
  }

  close() {
    this.db.close();
  }
}

/** @param {string} filename */
export function openDatabase(filename) {
  return new WrappedDatabase(
    new DatabaseSync(filename, { enableForeignKeyConstraints: false }),
  );
}
