import { RemoteDirectoryEntry } from '../service/RustDeskNapi';

export function sortRemoteFiles(entries: RemoteDirectoryEntry[], field: string,
  descending: boolean): RemoteDirectoryEntry[] {
  return entries.slice().sort((left: RemoteDirectoryEntry, right: RemoteDirectoryEntry): number => {
    const leftFolder: boolean = left.entryType === 0 || left.entryType === 2 || left.entryType === 3;
    const rightFolder: boolean = right.entryType === 0 || right.entryType === 2 || right.entryType === 3;
    if (leftFolder !== rightFolder) return leftFolder ? -1 : 1;
    let order: number = 0;
    if (field === 'size') {
      // Directory sizes do not represent their recursive contents.
      order = leftFolder ? 0 : left.size - right.size;
    } else if (field === 'modified') {
      order = left.modifiedTime - right.modifiedTime;
    } else if (field === 'type' && !leftFolder) {
      order = fileExtension(left.name).localeCompare(fileExtension(right.name));
    }
    if (order === 0) {
      order = left.name.localeCompare(right.name, 'zh-CN', { numeric: true, sensitivity: 'base' });
      if (order === 0) order = left.name.localeCompare(right.name);
    }
    return descending ? -order : order;
  });
}

function fileExtension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
}
