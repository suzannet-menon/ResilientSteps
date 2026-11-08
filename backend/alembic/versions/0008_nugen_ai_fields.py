"""Nugen AI support fields for incident_reports (WP14)

Additive only: metadata JSONB + AI provenance columns. No existing column is
altered. Revision ID: 0008. Revises: 0007.
"""

from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.execute(
        """
        ALTER TABLE incident_reports
        ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}';
        """
    )
    op.execute(
        """
        ALTER TABLE incident_reports
        ADD COLUMN IF NOT EXISTS model_name TEXT;
        """
    )
    op.execute(
        """
        ALTER TABLE incident_reports
        ADD COLUMN IF NOT EXISTS model_confidence DOUBLE PRECISION;
        """
    )
    op.execute(
        """
        ALTER TABLE incident_reports
        ADD COLUMN IF NOT EXISTS auto_moderated BOOLEAN NOT NULL DEFAULT FALSE;
        """
    )
    op.execute(
        """
        COMMENT ON COLUMN incident_reports.metadata IS
        'Free-form extras; .ai holds the Nugen classification payload';
        """
    )


def downgrade():
    op.execute("ALTER TABLE incident_reports DROP COLUMN IF EXISTS auto_moderated;")
    op.execute("ALTER TABLE incident_reports DROP COLUMN IF EXISTS model_confidence;")
    op.execute("ALTER TABLE incident_reports DROP COLUMN IF EXISTS model_name;")
    op.execute("ALTER TABLE incident_reports DROP COLUMN IF EXISTS metadata;")
