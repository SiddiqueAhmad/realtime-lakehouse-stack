"""
Schema compatibility rules for Debezium-Iceberg integration.

This module defines the rules for determining whether a Postgres schema change
can be automatically handled by Debezium-Iceberg or requires manual intervention.
"""

from enum import Enum
from typing import Dict, Tuple, Optional


class ChangeStatus(Enum):
    """Classification of schema change risk levels."""
    SAFE = "safe"  # Automatic handling, no intervention needed
    CAUTION = "caution"  # Works but may have unintended consequences
    MANUAL = "manual"  # Requires manual intervention


class ChangeType(Enum):
    """Types of schema changes."""
    ADD_COLUMN = "add_column"
    DROP_COLUMN = "drop_column"
    RENAME_COLUMN = "rename_column"
    ALTER_TYPE = "alter_type"
    ADD_CONSTRAINT = "add_constraint"
    DROP_CONSTRAINT = "drop_constraint"
    ALTER_DEFAULT = "alter_default"
    ALTER_NULLABLE = "alter_nullable"
    UNKNOWN = "unknown"


# Mapping of safe type expansions (from_type -> to_type)
# These are automatically handled by Debezium-Iceberg when allow-field-addition=true
SAFE_TYPE_EXPANSIONS = {
    # Integer expansions
    ('smallint', 'integer'): True,
    ('smallint', 'bigint'): True,
    ('integer', 'bigint'): True,
    ('int', 'bigint'): True,
    ('int2', 'int4'): True,
    ('int2', 'int8'): True,
    ('int4', 'int8'): True,
    
    # Numeric expansions
    ('integer', 'real'): True,
    ('integer', 'double precision'): True,
    ('bigint', 'double precision'): True,
    ('real', 'double precision'): True,
    ('int', 'float'): True,
    ('int', 'double'): True,
    ('float', 'double'): True,
    
    # Numeric precision expansions (if new precision/scale >= old)
    ('numeric', 'numeric'): 'check_precision',  # Needs precision comparison
    ('decimal', 'decimal'): 'check_precision',
    
    # String length expansions
    ('varchar', 'varchar'): 'check_length',  # Needs length comparison
    ('char', 'varchar'): True,
    ('char', 'text'): True,
    ('varchar', 'text'): True,
    
    # Date/time safe expansions
    ('date', 'timestamp'): False,  # Actually unsafe! timestamp has time component
    ('time', 'timestamp'): False,  # Unsafe - adds date component
    ('timestamp', 'timestamptz'): True,  # Can add timezone
}


# Type changes that are definitely unsafe and require manual intervention
UNSAFE_TYPE_CHANGES = {
    # Type narrowing
    ('bigint', 'integer'),
    ('bigint', 'smallint'),
    ('integer', 'smallint'),
    ('int8', 'int4'),
    ('int8', 'int2'),
    ('int4', 'int2'),
    ('double precision', 'real'),
    ('double precision', 'integer'),
    ('real', 'integer'),
    ('double', 'float'),
    ('double', 'int'),
    ('float', 'int'),
    
    # Semantic type changes
    ('varchar', 'integer'),
    ('text', 'integer'),
    ('varchar', 'date'),
    ('varchar', 'timestamp'),
    ('integer', 'varchar'),  # Can work but loses numeric operations
    ('boolean', 'varchar'),
    
    # Date/time narrowing
    ('timestamp', 'date'),
    ('timestamp', 'time'),
    ('timestamptz', 'timestamp'),
    ('timestamptz', 'date'),
    
    # Binary/text incompatibilities
    ('text', 'bytea'),
    ('bytea', 'text'),
}


def normalize_type(pg_type: str) -> str:
    """
    Normalize Postgres type names to canonical forms.
    
    Args:
        pg_type: Postgres type name (e.g., "VARCHAR(255)", "INT", "DECIMAL(10,2)")
    
    Returns:
        Normalized type name in lowercase without parameters
    """
    # Remove whitespace and convert to lowercase
    pg_type = pg_type.strip().lower()
    
    # Extract base type (remove length/precision parameters)
    if '(' in pg_type:
        base_type = pg_type.split('(')[0].strip()
    else:
        base_type = pg_type
    
    # Map aliases to canonical types
    type_aliases = {
        'int': 'integer',
        'int2': 'smallint',
        'int4': 'integer',
        'int8': 'bigint',
        'float4': 'real',
        'float8': 'double precision',
        'bool': 'boolean',
        'character varying': 'varchar',
    }
    
    return type_aliases.get(base_type, base_type)


def extract_type_parameters(pg_type: str) -> Optional[Tuple[int, ...]]:
    """
    Extract parameters from a Postgres type.
    
    Args:
        pg_type: Postgres type with parameters (e.g., "VARCHAR(255)", "DECIMAL(10,2)")
    
    Returns:
        Tuple of integer parameters, or None if no parameters
    """
    if '(' not in pg_type:
        return None
    
    params_str = pg_type[pg_type.index('(') + 1:pg_type.rindex(')')]
    try:
        return tuple(int(p.strip()) for p in params_str.split(','))
    except ValueError:
        return None


def evaluate_type_change(from_type: str, to_type: str) -> ChangeStatus:
    """
    Evaluate whether a type change is safe, requires caution, or needs manual intervention.
    
    Args:
        from_type: Original Postgres type
        to_type: New Postgres type
    
    Returns:
        ChangeStatus indicating the risk level
    """
    # Normalize types
    from_base = normalize_type(from_type)
    to_base = normalize_type(to_type)
    
    # No change
    if from_base == to_base:
        # Check if parameters changed (e.g., VARCHAR(100) -> VARCHAR(200))
        from_params = extract_type_parameters(from_type)
        to_params = extract_type_parameters(to_type)
        
        if from_params and to_params:
            # For varchar/char: length increase is safe
            if from_base in ('varchar', 'char'):
                if to_params[0] >= from_params[0]:
                    return ChangeStatus.SAFE
                else:
                    return ChangeStatus.MANUAL  # Length reduction
            
            # For numeric/decimal: precision/scale increase is safe
            elif from_base in ('numeric', 'decimal'):
                if len(to_params) >= 2 and len(from_params) >= 2:
                    # precision, scale
                    if to_params[0] >= from_params[0] and to_params[1] >= from_params[1]:
                        return ChangeStatus.SAFE
                    else:
                        return ChangeStatus.MANUAL  # Precision/scale reduction
        
        return ChangeStatus.SAFE  # Same type, same or no parameters
    
    # Check if it's a known unsafe change
    if (from_base, to_base) in UNSAFE_TYPE_CHANGES:
        return ChangeStatus.MANUAL
    
    # Check if it's a known safe expansion
    safe_result = SAFE_TYPE_EXPANSIONS.get((from_base, to_base))
    if safe_result is True:
        return ChangeStatus.SAFE
    elif safe_result == 'check_length':
        # Already handled above in the same-base-type case
        return ChangeStatus.MANUAL  # Conservative default
    elif safe_result == 'check_precision':
        # Already handled above
        return ChangeStatus.MANUAL
    
    # Unknown type change - be conservative
    return ChangeStatus.MANUAL


def evaluate_change(change_type: ChangeType, **kwargs) -> Tuple[ChangeStatus, str]:
    """
    Evaluate a schema change and return status + explanation.
    
    Args:
        change_type: Type of schema change
        **kwargs: Additional context (e.g., from_type, to_type, column_name)
    
    Returns:
        Tuple of (ChangeStatus, explanation message)
    """
    if change_type == ChangeType.ADD_COLUMN:
        return (
            ChangeStatus.SAFE,
            "Will be automatically added to Iceberg table (if allow-field-addition=true)"
        )
    
    elif change_type == ChangeType.DROP_COLUMN:
        return (
            ChangeStatus.CAUTION,
            "Column will remain in Iceberg table with NULL values for new records. "
            "Historical data still accessible."
        )
    
    elif change_type == ChangeType.RENAME_COLUMN:
        return (
            ChangeStatus.MANUAL,
            "Debezium treats column rename as DROP + ADD. Old column data will be lost "
            "for new records. Requires Iceberg table migration to preserve data."
        )
    
    elif change_type == ChangeType.ALTER_TYPE:
        from_type = kwargs.get('from_type')
        to_type = kwargs.get('to_type')
        
        if not from_type or not to_type:
            return (ChangeStatus.MANUAL, "Unable to determine type change safety")
        
        status = evaluate_type_change(from_type, to_type)
        
        if status == ChangeStatus.SAFE:
            msg = f"Safe type expansion: {from_type} → {to_type}"
        elif status == ChangeStatus.MANUAL:
            msg = (f"Incompatible type change: {from_type} → {to_type}. "
                   "Requires manual Iceberg table migration.")
        else:
            msg = f"Type change requires review: {from_type} → {to_type}"
        
        return (status, msg)
    
    elif change_type == ChangeType.ALTER_NULLABLE:
        return (
            ChangeStatus.CAUTION,
            "Iceberg schema doesn't enforce NOT NULL constraints. "
            "Application-level validation recommended."
        )
    
    elif change_type in (ChangeType.ADD_CONSTRAINT, ChangeType.DROP_CONSTRAINT):
        return (
            ChangeStatus.CAUTION,
            "Constraints aren't enforced in Iceberg. "
            "Has no effect on data replication but may affect application behavior."
        )
    
    elif change_type == ChangeType.ALTER_DEFAULT:
        return (
            ChangeStatus.SAFE,
            "Default value changes don't affect Iceberg schema. "
            "Only applies to new Postgres inserts."
        )
    
    else:
        return (
            ChangeStatus.MANUAL,
            "Unknown schema change type. Manual review required."
        )


# Debezium configuration check
def check_debezium_config(allow_field_addition: bool = True) -> str:
    """
    Generate a warning message based on Debezium configuration.
    
    Args:
        allow_field_addition: Value of debezium.sink.iceberg.allow-field-addition
    
    Returns:
        Warning message if configuration may cause issues
    """
    if not allow_field_addition:
        return (
            "⚠️  WARNING: allow-field-addition is set to false. "
            "New columns will NOT be automatically added to Iceberg tables. "
            "All schema changes will require manual intervention."
        )
    return ""
